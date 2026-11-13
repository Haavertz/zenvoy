vim.opt.runtimepath:prepend(vim.fn.getcwd())

local t = dofile("tests/helpers.lua")
local Draft = require("zenvoy.himalaya.draft")

local preview = "From: =?utf-8?Q?Bob?= <bob@example.com>\r\n"
   .. "To: Alice <alice@example.com>\r\nIn-Reply-To: <original@example.com>\r\n"
   .. "References: <older@example.com>\r\n\t<original@example.com>\r\n"
   .. "Subject: encoded subject ignored\r\nContent-Type: text/plain\r\n\r\n"
   .. "Ignore native quote and account signature in this preview"

local function source()
   return {
      subject = "Olá", body = "Original first line\nsecond line\n",
      from = { { email = "alice@example.com" } },
      reply_to = { { email = "replies@example.com" } },
      to = { { email = "BOB@example.com" }, { email = "carol@example.com" } },
      cc = { { email = "CAROL@example.com" }, { email = "dave@example.com" }, { email = "bob@example.com" } },
   }
end

t.test("prepares an editable quote and sender reply with native threading", function()
   local draft, err = Draft.reply(source(), preview, false)
   t.equal(nil, err)
   t.equal("replies@example.com", draft.to)
   t.equal("", draft.cc)
   t.equal("", draft.bcc)
   t.equal("Re: Olá", draft.subject)
   t.equal("\n\nalice@example.com wrote:\n> Original first line\n> second line", draft.body)
   t.equal("<original@example.com>", draft.reply_context.in_reply_to)
   t.equal("<older@example.com> <original@example.com>", draft.reply_context.references)
   t.equal("=?utf-8?Q?Bob?= <bob@example.com>", draft.reply_context.from)
   assert(not draft.body:find("signature", 1, true))
end)

t.test("reply-all removes the account and deduplicates across To and Cc", function()
   local draft = assert(Draft.reply(source(), preview, true))
   t.equal("replies@example.com, carol@example.com", draft.to)
   t.equal("dave@example.com", draft.cc)
end)

t.test("uses From when Reply-To is absent and original To for self-sent messages", function()
   local original = source()
   original.reply_to = {}
   t.equal("alice@example.com", assert(Draft.reply(original, preview)).to)
   original.from = { { email = "bob@example.com" } }
   t.equal("carol@example.com", assert(Draft.reply(original, preview)).to)
   original.subject = "re: Existing thread"
   t.equal(original.subject, assert(Draft.reply(original, preview)).subject)
end)

t.test("accepts missing thread IDs but rejects invalid native preview headers", function()
   local draft = assert(Draft.reply(source(), "From: bob@example.com\n\n", false))
   t.equal(nil, draft.reply_context.in_reply_to)
   for _, raw in ipairs({ "not mail", "To: a@example.com\n\n", "From: invalid\n\n",
      "From: bob@example.com\nFrom: evil@example.com\n\n", "From: bob@example.com\nBad header\n\n" }) do
      local result, err = Draft.reply(source(), raw)
      assert(result == nil and err, raw)
   end
end)

t.test("validates recipients without interpreting shell characters or display-name commas", function()
   local draft = { to = '"Doe, Jane" <jane@example.com>, bob@example.com', cc = "", bcc = "",
      subject = "--literal $(subject)", body = "`body`\nsecond line" }
   local validated = assert(Draft.validate(draft))
   t.equal("jane@example.com, bob@example.com", validated.to)
   t.equal(draft.subject, validated.subject)
   t.equal(draft.body, validated.body)
   t.equal('"Doe, Jane" <jane@example.com>, bob@example.com', draft.to)
   t.equal("", assert(Draft.validate({ to = "", cc = "cc@example.com", body = "" })).to)
end)

t.test("rejects header injection, malformed recipients, and empty recipient sets", function()
   for _, invalid in ipairs({
      {}, { to = "not-an-email" }, { to = "a@example.com\nBcc: evil@example.com" },
      { to = "a@example.com", subject = "one\rtwo" },
      { to = "a@example.com", cc = "a@example.com,,b@example.com" },
      { to = "a@example.com", bcc = '"unfinished <x@example.com>' },
      { to = "a@example.com", body = false },
      { to = "a@example.com", reply_context = { from = "bob@example.com", references = "a\nBcc: x" } },
   }) do
      local result, err = Draft.validate(invalid)
      assert(result == nil and type(err) == "string", vim.inspect(invalid))
   end
end)

t.test("defaults only absent fields and rejects invalid types consistently", function()
   local validated = assert(Draft.validate({ to = "a@example.com" }))
   for _, field in ipairs({ "cc", "bcc", "subject", "body" }) do t.equal("", validated[field]) end
   for _, field in ipairs({ "to", "cc", "bcc", "subject", "body", "reply_context" }) do
      for _, value in ipairs({ false, true, 1, {} }) do
         local draft = { to = "a@example.com", cc = "cc@example.com" }
         draft[field] = value
         local result, err = Draft.validate(draft)
         assert(result == nil and type(err) == "string", field .. "=" .. vim.inspect(value))
      end
   end
end)

t.test("adds only captured identity and threading while retaining compiled MIME bytes", function()
   local context = assert(Draft.reply(source(), preview)).reply_context
   local raw = "From: changed@example.com\r\nTo: edited@example.com\r\nSubject: New subject\r\n"
      .. "Content-Transfer-Encoding: quoted-printable\r\n\r\nEdited=20body\r\n"
   local final = assert(Draft.apply_context(raw, context))
   assert(final:find("From: " .. context.from, 1, true))
   assert(final:find("In-Reply-To: <original@example.com>", 1, true))
   assert(final:find("References: <older@example.com> <original@example.com>", 1, true))
   assert(final:find("To: edited@example.com", 1, true))
   assert(not final:find("changed@example.com", 1, true))
   assert(not final:find("Cc:", 1, true))
   assert(final:sub(-#"Edited=20body\r\n") == "Edited=20body\r\n")
   t.equal(raw, assert(Draft.apply_context(raw)))
end)

t.test("reply attribution names the sender and the original date", function()
   local original = source()
   original.from = { { name = "Alice Doe", email = "alice@example.com" } }
   original.date = 1788782400
   local draft = assert(Draft.reply(original, preview))
   local attribution = draft.body:match("^\n\n(On .-, Alice Doe <alice@example.com> wrote:)\n> Original first line")
   assert(attribution, draft.body)
   assert(attribution:find(require("zenvoy.utils.date").format_long(1788782400), 1, true), attribution)
   original.body = ""
   t.equal("", assert(Draft.reply(original, preview)).body)
end)

t.test("attachments must be existing absolute files", function()
   local file = vim.fn.tempname() .. "-zenvoy-draft.txt"
   vim.fn.writefile({ "content" }, file)
   t.equal({ file }, assert(Draft.validate({ to = "a@example.com", attachments = { file } })).attachments)
   t.equal({}, assert(Draft.validate({ to = "a@example.com" })).attachments)
   for _, invalid in ipairs({ "relative.txt", file .. ".missing", vim.fn.fnamemodify(file, ":h"), file .. "\n" }) do
      local result, err = Draft.validate({ to = "a@example.com", attachments = { invalid } })
      assert(result == nil and err, invalid)
   end
   assert(not Draft.validate({ to = "a@example.com", attachments = file }))
   vim.fn.delete(file)
end)

t.test("forward quotes the original headers and body and carries attachments", function()
   local original = source()
   original.from = { { name = "Alice", email = "alice@example.com" } }
   original.subject = "Olá\nworld"
   original.date = 1788782400
   local draft = assert(Draft.forward(original, { "/tmp/report.pdf" }))
   t.equal("Fwd: Olá world", draft.subject)
   t.equal({ "/tmp/report.pdf" }, draft.attachments)
   t.equal("", draft.to)
   t.equal(nil, draft.reply_context)
   assert(draft.body:find("^\n\n%-%-%-%-%-%-%-%-%-%- Forwarded message %-%-%-%-%-%-%-%-%-\nFrom: Alice <alice@example.com>\nDate: "),
      draft.body)
   assert(draft.body:find("Subject: Olá world\nTo: BOB@example.com, carol@example.com\nCc: CAROL@example.com, "
      .. "dave@example.com, bob@example.com\n\nOriginal first line\nsecond line$"), draft.body)
   original.subject = "FW: already forwarded"
   t.equal("FW: already forwarded", assert(Draft.forward(original)).subject)
   assert(not Draft.forward(original, { "relative.pdf" }))
end)

t.finish("draft_spec")
