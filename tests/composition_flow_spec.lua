vim.opt.runtimepath:prepend(vim.fn.getcwd())
local t = dofile("tests/helpers.lua")
local jobs, choices, notices = {}, {}, {}
vim.system = function(command, options, callback)
   local job = { command = command, options = options, exit = callback, kills = 0 }
   function job:kill() self.kills = self.kills + 1 end
   jobs[#jobs + 1] = job
   return job
end
vim.fn.filereadable = function() return 1 end
vim.ui.select = function(items, options, callback) choices[#choices + 1] = { items = items, callback = callback } end
vim.notify = function(text) notices[#notices + 1] = text end
local app, state, ui = require("zenvoy"), require("zenvoy.state"), require("zenvoy.ui")

local function flush(ms) vim.wait(ms or 25, function() return false end, 5) end
local function complete(job, output, code)
   assert(job, "expected a backend request")
   job.exit({ code = code or 0, stdout = output or "", stderr = code and "send failed" or "" })
   flush()
end
local function map(bufnr, key)
   for _, value in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if value.lhs == key then return value.callback end
   end
   error("missing mapping " .. key)
end
local function field(name)
   for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "zenvoy-compose-" .. name then return buf end
   end
end
local function write(name, text)
   vim.api.nvim_buf_set_lines(assert(field(name), "missing field " .. name), 0, -1, false, vim.split(text, "\n", { plain = true }))
end
local function content(name)
   return table.concat(vim.api.nvim_buf_get_lines(field(name), 0, -1, false), "\n")
end
local function open()
   ui.close(true)
   jobs, choices, notices = {}, {}, {}
   app.setup()
   app.open()
   complete(jobs[1], '{"mailboxes":[{"id":"native/archive"}]}')
   complete(jobs[2], '{"envelopes":[{"id":"original-id","subject":"Hello"}]}')
end
local function confirm_send()
   map(field("body"), "<C-S>")()
   choices[#choices].callback("Send")
   flush()
end

t.test("c opens a working form and only confirmed submissions reach the sending backend", function()
   open()
   local previous = state.listing_popup.winid
   map(state.listing_popup.bufnr, "c")()
   assert(field("to"), "c must open the composer")
   write("to", "bob@example.test")
   write("cc", "carol@example.test")
   write("bcc", "hidden@example.test")
   write("subject", "Olá")
   write("body", "First line\nSecond line")
   map(field("body"), "<C-S>")()
   t.equal(2, #jobs)
   choices[1].callback("Cancel")
   t.equal("First line\nSecond line", content("body"))
   confirm_send()
   t.equal("compose", jobs[3].command[3])
   t.equal("First line\nSecond line", jobs[3].options.stdin)
   assert(not vim.tbl_contains(jobs[3].command, "--send"))
   local raw = "From: Me <me@example.test>\r\nTo: bob@example.test\r\nSubject: Hello\r\n\r\nBuilt body\r\n"
   complete(jobs[3], raw)
   t.equal("send", jobs[4].command[3])
   assert(jobs[4].options.stdin:find("Built body", 1, true))
   complete(jobs[4], "")
   t.equal(nil, field("body"))
   t.equal(previous, vim.api.nvim_get_current_win())
   assert(state.is_open)
end)

t.test("reply-all preserves its original mailbox, editable quote and threading through send", function()
   open()
   map(state.listing_popup.bufnr, "s")()
   map(state.sidebar_popup.bufnr, "<CR>")()
   complete(jobs[3], '{"envelopes":[{"id":"original-id","subject":"Hello"}]}')
   map(state.listing_popup.bufnr, "R")()
   t.equal(5, #jobs)
   local source = vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/messages/plain.json"), "\n"))
   source.parts[1].headers[#source.parts[1].headers + 1] = {
      name = "Reply-To", value = { Address = { List = { { address = "reply@example.test" } } } },
   }
   for index = 4, 5 do
      local job = jobs[index]
      assert(vim.tbl_contains(job.command, "native/archive") or vim.tbl_contains(job.command, "--mailbox=native/archive"))
      assert(not vim.tbl_contains(job.command, "--seen"), "reply preparation is a peek")
      if job.command[3] == "read" then
         complete(job, vim.json.encode(source))
      else
         t.equal("reply", job.command[3])
         complete(job, "From: Me <me@example.test>\r\nIn-Reply-To: <original@example.test>\r\nReferences: <parent@example.test> <original@example.test>\r\n\r\nIgnored preview quote")
      end
   end
   assert(content("to"):find("reply@example.test", 1, true), content("to"))
   assert(content("body"):find("> Hello, Bob!", 1, true), content("body"))
   write("body", "Edited reply\n\n> Only the sentence I kept")
   write("cc", "")
   confirm_send()
   t.equal("Edited reply\n\n> Only the sentence I kept", jobs[6].options.stdin)
   complete(jobs[6], "From: Me <me@example.test>\r\nTo: reply@example.test\r\nSubject: Re: Hello\r\n\r\nEdited reply\r\n")
   local sent = jobs[7].options.stdin
   assert(sent:find("In-Reply-To: <original@example.test>", 1, true), sent)
   assert(sent:find("References: <parent@example.test> <original@example.test>", 1, true), sent)
   assert(not sent:find("Ignored preview quote", 1, true))
   complete(jobs[7], "")
   t.equal(nil, field("body"))
end)

t.test("API close protects changed drafts and external close lets dispatched delivery finish", function()
   open()
   map(state.listing_popup.bufnr, "c")()
   write("to", "bob@example.test")
   write("body", "Keep this")
   app.close()
   choices[#choices].callback("Keep editing")
   t.equal(true, state.is_open)
   t.equal("Keep this", content("body"))
   confirm_send()
   complete(jobs[3], "From: me@example.test\r\nTo: bob@example.test\r\n\r\nKeep this")
   local sent = jobs[4]
   vim.api.nvim_win_close(state.sidebar_popup.winid, true)
   flush()
   t.equal(false, state.is_open)
   t.equal(nil, field("body"))
   t.equal(0, sent.kills)
   open()
   map(state.listing_popup.bufnr, "c")()
   write("body", "New draft")
   complete(sent, "")
   t.equal("New draft", content("body"))
   assert(notices[#notices]:find("sent", 1, true))
end)

ui.close(true)
t.finish("composition_flow_spec")
