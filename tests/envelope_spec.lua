vim.opt.runtimepath:prepend(vim.fn.getcwd())

local has_nui = pcall(require, "nui.line")

if not has_nui then
   local Line = {}
   Line.__index = Line

   setmetatable(Line, {
      __call = function()
         return setmetatable({ parts = {} }, Line)
      end,
   })

   function Line:append(content)
      table.insert(self.parts, content)
   end

   function Line:render(bufnr, _, line_number)
      vim.api.nvim_buf_set_lines(
         bufnr,
         line_number - 1,
         line_number,
         false,
         { table.concat(self.parts) }
      )
   end

   package.preload["nui.line"] = function()
      return Line
   end
end

local envelope = require("zenvoy.ui.envelope")
local state = require("zenvoy.state")
local bufnr = vim.api.nvim_create_buf(false, true)

vim.bo[bufnr].modifiable = false
vim.bo[bufnr].readonly = true

local envelopes = {
   {
      id = "30222",
      subject = "Unread message with accented text: confirmação",
      from = { { name = "Alice Smith", email = "alice@example.com" } },
      flags = {},
      date = "2026-09-06T01:00:00Z",
      ["has-attachment"] = false,
   },
   {
      id = "30221",
      subject = "Seen and flagged 📰",
      from = { { name = vim.NIL, email = "bob@example.com" } },
      flags = {
         { iana = "seen", raw = "\\Seen" },
         { iana = "flagged", raw = "\\Flagged" },
      },
      date = "2026-09-05T01:00:00Z",
      ["has-attachment"] = true,
   },
}

envelope.render(bufnr, envelopes)

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

assert(#lines == 2, vim.inspect(lines))
assert(lines[1]:find("■", 1, true), lines[1])
assert(lines[1]:find("Alice Smith", 1, true), lines[1])
assert(lines[1]:find("…", 1, true), lines[1])
assert(lines[2]:find("■", 1, true), lines[2])
assert(lines[2]:find("@", 1, true), lines[2])
assert(lines[2]:find("bob@example.com", 1, true), lines[2])
assert(lines[2]:find("Seen and flagged 📰", 1, true), lines[2])

local first_date_column = vim.fn.strdisplaywidth(lines[1]:match("^(.*)%(") or "")
local second_date_column = vim.fn.strdisplaywidth(lines[2]:match("^(.*)%(") or "")

assert(first_date_column == second_date_column, vim.inspect({ first_date_column, second_date_column }))
assert(state.envelopes == envelopes, "renderer must expose the rendered envelopes in state")
assert(state.current_envelope_count == 2, "renderer must track the envelope count")
assert(vim.bo[bufnr].filetype == "zenvoy-envelope-listing", vim.bo[bufnr].filetype)
assert(vim.bo[bufnr].modifiable == false, "envelope buffer must be non-modifiable after rendering")
assert(vim.bo[bufnr].readonly == true, "envelope buffer must be read-only after rendering")

envelope.render(bufnr, {})

lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

assert(vim.deep_equal(lines, { "No emails in this mailbox" }), vim.inspect(lines))
assert(state.current_envelope_count == 0, "empty renderer must reset the envelope count")

print("envelope_spec: 2 tests passed")
