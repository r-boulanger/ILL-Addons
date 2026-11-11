-- ILL Strategy Agent  v2.1.0  (no AI, no API key needed)
-- Adds a "Citation Check" tab to the ILLiad request form.
-- Lua gathers the request's citation fields and hands them to verify.html
-- (in this same folder). verify.html checks the citation against free
-- databases (Crossref, OpenAlex, Open Library, Unpaywall) and suggests a
-- strategy from rules you can edit at the top of that file.

-- Names are unique to this addon so they can't clash with another addon
-- (or an older copy of this one) that is also open on the request form.
local FORM_NAME    = "ILL Citation Check"
local RIBBON_NAME  = "Citation Check"
local BROWSER_NAME = "CitationCheckBrowser"

local settings = {}
settings.ContactEmail     = GetSetting("ContactEmail") or ""
settings.CatalogSearchURL = GetSetting("CatalogSearchURL") or ""
settings.LinkResolverURL  = GetSetting("LinkResolverURL") or ""
settings.AlmaResolverURL  = GetSetting("AlmaResolverURL") or ""
settings.PdfSaveFolder    = GetSetting("PdfSaveFolder") or ""
settings.AutoFetchPdf     = GetSetting("AutoFetchPdf")
settings.ReviewPdfBeforeSave = GetSetting("ReviewPdfBeforeSave")
settings.AutoRun          = GetSetting("AutoRun")
settings.EResourceUsername = GetSetting("EResourceUsername") or "Lending"
settings.CopyTNOnOpen     = GetSetting("CopyTNOnOpen")
settings.CitationBox      = GetSetting("CitationBox")
-- EBSCOhost API (EIT): profile + password. Values still reading ENTER_...
-- (the placeholders in Config.xml) count as blank, which turns the EBSCO route off.
local function EbscoSetting(name)
  local v = tostring(GetSetting(name) or "")
  v = string.gsub(string.gsub(v, "^%s+", ""), "%s+$", "")
  if string.match(string.upper(v), "^ENTER_") then return "" end
  return v
end
settings.EbscoProfile     = EbscoSetting("EbscoProfile")
settings.EbscoPassword    = EbscoSetting("EbscoPassword")

local interfaceMngr = nil
local agentForm = { Form = nil, Browser = nil, RibbonPage = nil }
local pdfPreview = { browser = nil }   -- "PDF Preview" tab (eResource requests)

-- Transaction fields sent to the agent. Add or remove names freely;
-- any field that is empty or does not exist on your system is skipped.
local FIELDS = {
  "TransactionNumber", "Username", "ProcessType", "RequestType", "DocumentType", "TransactionStatus",
  -- Articles / chapters
  "PhotoArticleTitle", "PhotoArticleAuthor", "PhotoJournalTitle",
  "PhotoJournalVolume", "PhotoJournalIssue", "PhotoJournalMonth",
  "PhotoJournalYear", "PhotoJournalInclusivePages",
  "PhotoItemAuthor", "PhotoItemEdition", "PhotoItemPlace", "PhotoItemPublisher",
  -- Loans
  "LoanTitle", "LoanAuthor", "LoanPublisher", "LoanPlace", "LoanDate", "LoanEdition",
  -- Identifiers
  "ISSN", "ESPNumber", "DOI", "CallNumber",
  -- Where the patron found it / patron notes
  "CitedIn", "CitedTitle", "CitedDate", "CitedVolume", "CitedPages", "SpecIns",
  -- Patron preferences and history
  "AcceptNonEnglish", "AcceptAlternateEdition", "NotWantedAfter", "LendingString"
}

-- ---------- helpers ----------

local currentStep = "starting"

local function Log(msg)
  pcall(LogDebug, "ILL Strategy Agent: " .. tostring(msg))
end

local function Step(name)
  currentStep = name
  Log("step: " .. name)
end

-- ILLiad reports every .NET error as "A .NET exception occured in user-code".
-- This digs out the real message(s) hidden inside it.
local function ErrorText(err)
  local out = { tostring(err) }
  local e = err
  for _ = 1, 5 do
    local ok, inner = pcall(function() return e.InnerException end)
    if not ok or inner == nil then break end
    local okm, msg = pcall(function() return inner.Message end)
    if okm and msg ~= nil then table.insert(out, tostring(msg)) end
    e = inner
  end
  if #out == 1 then
    local okm, msg = pcall(function() return err.Message end)
    if okm and msg ~= nil and tostring(msg) ~= tostring(err) then table.insert(out, tostring(msg)) end
  end
  return table.concat(out, "\n  -> ")
end

local function ShowError(title, err)
  local text = title .. "\n\nFailed at step: " .. currentStep .. "\nError: " .. ErrorText(err)
  Log("ERROR " .. text)
  if interfaceMngr ~= nil then
    pcall(function() interfaceMngr:ShowMessage(text, "ILL Strategy Agent") end)
  end
end

local function Field(name)
  local ok, value = pcall(GetFieldValue, "Transaction", name)
  if ok and value ~= nil then
    local s = tostring(value)
    if s ~= "" and s ~= "nil" then return s end
  elseif not ok then
    Log("field " .. name .. " not available")
  end
  return nil
end

-- Encode a value for use in a URL (spaces, &, #, accents, etc.)
local function UrlEncode(s)
  s = tostring(s)
  s = string.gsub(s, "\r?\n", " ")
  s = string.gsub(s, "([^%w%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return s
end

-- Encode a Windows folder path for a file:/// URL (keeps / and :)
local function PathEncode(p)
  p = string.gsub(p, "\\", "/")
  p = string.gsub(p, "/+$", "")
  p = string.gsub(p, "([^%w%-_%.~/:])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return p
end

-- Same check Atlas uses in its own addons: WebView2 needs ILLiad 9.2.4+.
local function WebView2Enabled()
  local ok, result = pcall(function()
    return AddonInfo.Browsers ~= nil and AddonInfo.Browsers.WebView2 == true
  end)
  return ok and result == true
end

-- Picks the page mode for this request from the request's Username:
--   eresource: Username is "Lending" (the EResourceUsername setting;
--              capitals and surrounding spaces are ignored)
--   borrowing: any other username
local function Clean(s)
  s = string.gsub(tostring(s or ""), "^%s+", "")
  s = string.gsub(s, "%s+$", "")
  return string.lower(s)
end

local function DetectMode()
  local username = Clean(Field("Username"))
  local target = Clean(settings.EResourceUsername)
  if target == "" then target = "lending" end
  if username == target then return "eresource" end
  return "borrowing"
end

local function SettingIsTrue(v)
  return v == true or string.lower(tostring(v)) == "true"
end

-- ---------- TN to clipboard ----------

local function SetClipboard(text)
  local ok, err = pcall(function()
    luanet.load_assembly("System.Windows.Forms")
    local Clipboard = luanet.import_type("System.Windows.Forms.Clipboard")
    Clipboard.SetText(tostring(text))
  end)
  if not ok then Log("clipboard: " .. ErrorText(err)) end
  return ok
end

-- Copies the request's transaction number when the Citation Check tab opens
function CopyTN()
  local tn = Field("TransactionNumber")
  if tn ~= nil and tn ~= "" then SetClipboard(tn) end
end

-- ---------- Citation box on other websites ----------
-- When you leave verify.html for another site in this tab (a link on the
-- checker opens in the same tab inside ILLiad), a small citation box is placed
-- in the corner of every page. It is never shown on the checker itself.
-- citationText is one "Label<TAB>Value" pair per line. It starts from the
-- request's fields; verify.html replaces it with the verified citation
-- (SetCitation) once the check is done.

citationText = ""

function CitationFromFields()
  local lines = {}
  local function add(label, value)
    if value ~= nil and tostring(value) ~= "" then table.insert(lines, label .. "\t" .. tostring(value)) end
  end
  add("TN", Field("TransactionNumber"))
  add("Status", "As requested (not verified yet)")
  if Field("LoanTitle") and not Field("PhotoArticleTitle") then
    add("Title", Field("LoanTitle"))
    add("Author", Field("LoanAuthor"))
    add("Publisher", Field("LoanPublisher"))
    add("Edition", Field("LoanEdition"))
    add("Year", Field("LoanDate"))
    add("ISBN", Field("ISSN"))
  else
    add("Title", Field("PhotoArticleTitle"))
    add("Author", Field("PhotoArticleAuthor"))
    add("Journal", Field("PhotoJournalTitle"))
    add("Volume", Field("PhotoJournalVolume"))
    add("Issue", Field("PhotoJournalIssue"))
    add("Year", Field("PhotoJournalYear"))
    add("Pages", Field("PhotoJournalInclusivePages"))
    add("ISSN", Field("ISSN"))
  end
  add("DOI", Field("DOI"))
  return table.concat(lines, "\n")
end

-- Called by verify.html through the bridge with the verified citation
function SetCitation(text)
  if text ~= nil and tostring(text) ~= "" then
    citationText = tostring(text)
    RefreshBoxScript()
  end
  return "OK"
end

local function OnChecker(addr)
  addr = string.lower(tostring(addr or ""))
  return addr == "" or string.sub(addr, 1, 5) == "file:" or string.sub(addr, 1, 6) == "about:" or string.find(addr, "verify.html", 1, true) ~= nil
end

-- The box itself. Called as (text, minimized). Safe to run more than once on a
-- page: a second run replaces the box (new citation text) and keeps its spot.
-- It lives in a shadow root on <html> (not <body>, which some sites replace),
-- and puts itself back if the page's own scripts remove it.
local CITATION_BOX_SCRIPT = [[
(function (text, minimized) {
  if (window.top !== window) { return 'frame'; }
  var proto = String(location.protocol || '');
  if (proto !== 'http:' && proto !== 'https:') { return 'skip'; }
  var old = document.getElementById('illcheck-cite-host');
  var keepPos = old ? { left: old.style.left, top: old.style.top, right: old.style.right } : null;
  if (typeof window.__illcheckMin === 'boolean') { minimized = window.__illcheckMin; }
  window.__illcheckMin = !!minimized;
  if (old) { old.remove(); }
  var rows = String(text || '').split('\n').map(function (l) { var i = l.indexOf('\t'); return i > 0 ? [l.slice(0, i), l.slice(i + 1)] : null; })
    .filter(function (r) { return r && r[1]; });
  var tn = '', all = [];
  rows.forEach(function (r) { if (r[0] === 'TN') { tn = r[1]; } if (r[0] !== 'Status') { all.push(r[0] + ': ' + r[1]); } });
  var host = document.createElement('div');
  host.id = 'illcheck-cite-host';
  host.setAttribute('data-illcheck', '1');
  host.style.cssText = 'position:fixed;top:12px;right:12px;z-index:2147483647;display:block;';
  if (keepPos) { host.style.left = keepPos.left; host.style.top = keepPos.top || '12px'; host.style.right = keepPos.right; }
  var root = host.attachShadow ? host.attachShadow({ mode: 'open' }) : host;
  var css = document.createElement('style');
  css.textContent =
    ':host{all:initial}' +
    '.box{width:330px;max-width:calc(100vw - 24px);background:#000;color:#fff;border:1px solid #333a42;border-radius:8px;box-shadow:0 6px 24px rgba(0,0,0,.45);font:13px/1.4 "Segoe UI",system-ui,sans-serif;text-align:left}' +
    '.hd{display:flex;align-items:center;gap:8px;padding:7px 10px;border-bottom:1px solid #333a42;cursor:move;user-select:none}' +
    '.hd b{font-size:13px}.hd .tn{color:#a3adb8;font-size:12px;flex:1}' +
    '.box.min{width:auto}.box.min .bd{display:none}.box.min .hd{border-bottom:0}' +
    '.bd{max-height:60vh;overflow:auto;padding:6px 10px 10px}' +
    '.st{color:#a3adb8;font-size:11px;margin:2px 0 6px}' +
    '.r{display:flex;gap:8px;padding:3px 0;border-bottom:1px solid #161a1f}.r:last-of-type{border-bottom:0}' +
    '.k{color:#a3adb8;width:62px;flex:none;font-size:12px;padding-top:1px}' +
    '.v{flex:1;cursor:pointer;word-break:break-word;border-radius:4px;padding:0 3px;margin:0 -3px}.v:hover{background:#161a1f}' +
    '.v.ok{color:#7fd69b}' +
    'button{font:inherit;font-size:12px;background:#161a1f;color:#fff;border:1px solid #333a42;border-radius:6px;padding:3px 9px;cursor:pointer}' +
    'button:hover{border-color:#6cb4e8}.hd button{padding:0 8px;line-height:20px}' +
    '.ft{display:flex;gap:6px;flex-wrap:wrap;margin-top:8px}.ft .back{background:#6cb4e8;color:#000;border-color:#6cb4e8}' +
    '.note{color:#a3adb8;font-size:11px;margin-top:6px}';
  root.appendChild(css);
  var box = document.createElement('div'); box.className = 'box';
  var hd = document.createElement('div'); hd.className = 'hd';
  var title = document.createElement('b'); title.textContent = 'Citation';
  var tnEl = document.createElement('span'); tnEl.className = 'tn'; tnEl.textContent = tn ? 'TN ' + tn : '';
  var minBtn = document.createElement('button'); minBtn.type = 'button';
  hd.appendChild(title); hd.appendChild(tnEl); hd.appendChild(minBtn);
  var bd = document.createElement('div'); bd.className = 'bd';
  function copy(t, el) {
    var done = function () { if (!el) { return; } var o = el.textContent; el.textContent = 'Copied'; el.classList.add('ok'); setTimeout(function () { el.textContent = o; el.classList.remove('ok'); }, 1000); };
    try { navigator.clipboard.writeText(t).then(done, fallback); } catch (e) { fallback(); }
    function fallback() { var ta = document.createElement('textarea'); ta.value = t; ta.style.cssText = 'position:fixed;left:-9999px'; root.appendChild(ta); ta.select(); try { document.execCommand('copy'); done(); } catch (e) { } ta.remove(); }
  }
  rows.forEach(function (r) {
    if (r[0] === 'Status') { var st = document.createElement('div'); st.className = 'st'; st.textContent = r[1]; bd.appendChild(st); return; }
    var row = document.createElement('div'); row.className = 'r';
    var k = document.createElement('span'); k.className = 'k'; k.textContent = r[0];
    var v = document.createElement('span'); v.className = 'v'; v.textContent = r[1]; v.title = 'Click to copy';
    v.onclick = function () { copy(r[1], v); };
    row.appendChild(k); row.appendChild(v); bd.appendChild(row);
  });
  var ft = document.createElement('div'); ft.className = 'ft';
  var allBtn = document.createElement('button'); allBtn.type = 'button'; allBtn.textContent = 'Copy all';
  allBtn.onclick = function () { copy(all.join('\n'), allBtn); };
  var back = document.createElement('button'); back.type = 'button'; back.className = 'back'; back.textContent = '\u2190 Back to Citation Check';
  var note = document.createElement('div'); note.className = 'note'; note.textContent = 'Click any value to copy it.';
  back.onclick = function () {
    var here = location.href; history.back();
    setTimeout(function () { if (location.href === here) { note.textContent = 'Click Check Citation in the ribbon to go back.'; } }, 800);
  };
  ft.appendChild(back); ft.appendChild(allBtn);
  bd.appendChild(ft); bd.appendChild(note);
  box.appendChild(hd); box.appendChild(bd); root.appendChild(box);
  function setMin(min, tell) {
    window.__illcheckMin = min;
    box.classList.toggle('min', min);
    minBtn.textContent = min ? '+' : '\u2013'; minBtn.title = min ? 'Expand' : 'Minimize';
    // tell the addon, so the next website opens the box the same way
    if (tell) { try { window.chrome.webview.postMessage('illcheck-min:' + (min ? '1' : '0')); } catch (e) { } }
  }
  setMin(!!minimized, false);
  minBtn.onclick = function () { setMin(!box.classList.contains('min'), true); };
  hd.addEventListener('mousedown', function (e) {
    if (e.target === minBtn) { return; }
    var r = host.getBoundingClientRect(), dx = e.clientX - r.left, dy = e.clientY - r.top;
    function mv(ev) { host.style.left = Math.max(0, Math.min(window.innerWidth - 60, ev.clientX - dx)) + 'px'; host.style.top = Math.max(0, Math.min(window.innerHeight - 30, ev.clientY - dy)) + 'px'; host.style.right = 'auto'; }
    function up() { document.removeEventListener('mousemove', mv, true); document.removeEventListener('mouseup', up, true); }
    document.addEventListener('mousemove', mv, true); document.addEventListener('mouseup', up, true); e.preventDefault();
  });
  function attach() {
    var parent = document.documentElement || document.body;
    if (parent && !host.isConnected) { parent.appendChild(host); }
  }
  attach();
  // Sites that rebuild the page (or wipe <body>) would remove the box: put it back.
  if (window.__illcheckKeep) { clearInterval(window.__illcheckKeep); }
  window.__illcheckKeep = setInterval(function () {
    if (document.getElementById('illcheck-cite-host') !== host) {
      var other = document.getElementById('illcheck-cite-host');
      if (other && other !== host) { clearInterval(window.__illcheckKeep); return; }   // a newer box took over
      attach();
    }
  }, 1000);
  try {
    if (window.__illcheckObs) { window.__illcheckObs.disconnect(); }
    window.__illcheckObs = new MutationObserver(function () { if (!host.isConnected) { attach(); } });
    window.__illcheckObs.observe(document, { childList: true, subtree: true });
  } catch (e) { }
  return 'ok';
})
]]

local function JsString(s)
  s = tostring(s or "")
  s = string.gsub(s, "\\", "\\\\")
  s = string.gsub(s, "\"", "\\\"")
  s = string.gsub(s, "\r", "\\r")
  s = string.gsub(s, "\n", "\\n")
  s = string.gsub(s, "\t", "\\t")
  s = string.gsub(s, "</", "<\\/")
  return "\"" .. s .. "\""
end

-- ---------- Keeping the box on every page ----------
-- Main route: WebView2 runs a registered script on every new page in this tab
-- (AddScriptToExecuteOnDocumentCreated), so the box doesn't depend on ILLiad
-- noticing each page load. The script is re-registered when the citation or the
-- minimized setting changes. Fallback (no WebView2): ILLiad's page handler.
local boxState = { minimized = false, ids = {}, tasks = {}, hooked = false }

local function MainCore()
  local core = nil
  pcall(function() core = agentForm.Browser.WebBrowser.CoreWebView2 end)
  return core
end

local function BoxBootstrap()
  return "(function(){var run=function(){try{(" .. CITATION_BOX_SCRIPT .. ")(" .. JsString(citationText) .. "," ..
    (boxState.minimized and "true" or "false") .. ");}catch(e){}};" ..
    "if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',run);}else{run();}" ..
    "window.addEventListener('load',function(){if(!document.getElementById('illcheck-cite-host')){run();}});})();"
end

-- Registers the current box script for future pages (and drops older versions)
function RefreshBoxScript()
  local core = MainCore()
  if core == nil or citationText == "" then return false end
  local ok, err = pcall(function()
    -- collect ids of earlier registrations that have finished, then remove them all
    local pending = {}
    for _, t in ipairs(boxState.tasks) do
      local done, id = pcall(function() if t.IsCompleted then return tostring(t.Result) end return nil end)
      if done and id ~= nil then table.insert(boxState.ids, id) else table.insert(pending, t) end
    end
    boxState.tasks = pending
    for _, id in ipairs(boxState.ids) do pcall(function() core:RemoveScriptToExecuteOnDocumentCreated(id) end) end
    boxState.ids = {}
    table.insert(boxState.tasks, core:AddScriptToExecuteOnDocumentCreatedAsync(BoxBootstrap()))
    if not boxState.hooked then
      core.WebMessageReceived:Add(function(sender, args) OnBoxMessage(args) end)
      boxState.hooked = true
    end
  end)
  if not ok then Log("citation box script: " .. ErrorText(err)) end
  return ok
end

-- The box's minimize button reports here, so the next website opens it the same way
function OnBoxMessage(args)
  pcall(function()
    local msg = tostring(args:TryGetWebMessageAsString() or "")
    local v = string.match(msg, "^illcheck%-min:([01])$")
    if v == nil then return end
    local min = (v == "1")
    if min ~= boxState.minimized then
      boxState.minimized = min
      RefreshBoxScript()
    end
  end)
end

-- Page-handler test (fallback, and for the page currently shown): true on a
-- website (not the checker) that has no box yet
function CitationBoxNeeded()
  local ok, need = pcall(function()
    if citationText == "" then return false end
    if not boxState.hooked then RefreshBoxScript() end       -- WebView2 may only now be ready
    if OnChecker(agentForm.Browser.Address) then return false end
    local r = agentForm.Browser:EvaluateScript("(function(){return !!((document.documentElement||document.body) && !document.getElementById('illcheck-cite-host'));})()")
    if r == nil or not r.Success then return false end
    local v = string.lower(tostring(r.Result))
    return v == "true" or v == "1"
  end)
  return ok and need == true
end

-- Page handler: puts the box on the page
function ShowCitationBox()
  local ok, err = pcall(function()
    if OnChecker(agentForm.Browser.Address) then return end
    agentForm.Browser:ExecuteScript(CITATION_BOX_SCRIPT, { citationText, boxState.minimized })
  end)
  if not ok then Log("citation box: " .. ErrorText(err)) end
end

-- ---------- entry point ----------

local function Setup()
  Step("get interface manager")
  interfaceMngr = GetInterfaceManager()

  Step("create form")
  agentForm.Form = interfaceMngr:CreateForm(FORM_NAME, "Script")

  local browserType = "Chromium"
  if WebView2Enabled() then browserType = "WebView2" end

  Step("create " .. browserType .. " browser")
  local ok, result = pcall(function()
    return agentForm.Form:CreateBrowser(BROWSER_NAME, "Citation Check", RIBBON_NAME, browserType)
  end)
  if ok and result ~= nil then
    agentForm.Browser = result
  elseif browserType == "WebView2" then
    Log("WebView2 failed (" .. ErrorText(result) .. "), trying Chromium")
    Step("create Chromium browser (fallback)")
    agentForm.Browser = agentForm.Form:CreateBrowser(BROWSER_NAME .. "2", "Citation Check", RIBBON_NAME, "Chromium")
  else
    error(result, 0)
  end

  -- Optional cosmetic setting used by Atlas's addons; ignore if unsupported.
  pcall(function() agentForm.Browser.TextVisible = false end)

  -- CreateBrowser made a ribbon page named RIBBON_NAME; add the button to it.
  Step("add Check Citation button")
  local okBtn, errBtn = pcall(function()
    agentForm.RibbonPage = agentForm.Form:GetRibbonPage(RIBBON_NAME)
    agentForm.RibbonPage:CreateButton("Check Citation", GetClientImage("Search32"), "LoadAgent", "Citation")
    if EbscoConfigured() then
      agentForm.RibbonPage:CreateButton("Test EBSCO", GetClientImage("Tools16"), "TestEbsco", "Citation")
    end
  end)
  if not okBtn then Log("button skipped: " .. ErrorText(errBtn)) end

  -- eResource requests get a "PDF Preview" tab for reviewing fetched PDFs
  if browserType == "WebView2" and DetectMode() == "eresource" then
    Step("create PDF Preview browser")
    local okP, errP = pcall(function()
      pdfPreview.browser = agentForm.Form:CreateBrowser("PdfPreviewBrowser", "PDF Preview", "PDF Preview", "WebView2")
      pcall(function() pdfPreview.browser.TextVisible = false end)
    end)
    if not okP then Log("PDF Preview tab skipped: " .. ErrorText(errP)); pdfPreview.browser = nil end
  end

  -- Citation box: shown on top of any website opened from the checker in this tab
  if settings.CitationBox == nil or SettingIsTrue(settings.CitationBox) then
    Step("register citation box")
    citationText = CitationFromFields()
    local okH, errH = pcall(function()
      agentForm.Browser:RegisterPageHandler("custom", "CitationBoxNeeded", "ShowCitationBox", true)
    end)
    if not okH then Log("citation box page handler skipped: " .. ErrorText(errH)) end
    RefreshBoxScript()                                   -- may be too early; CitationBoxNeeded retries
  end

  Step("show form")
  agentForm.Form:Show()

  if settings.CopyTNOnOpen == nil or SettingIsTrue(settings.CopyTNOnOpen) then
    Step("copy TN to clipboard")
    CopyTN()
  end

  LoadAgent(not SettingIsTrue(settings.AutoRun))
end

function Init()
  local ok, err = pcall(Setup)
  if not ok then
    ShowError("The Citation Check tab could not start.", err)
  end
end

-- ---------- Alma link resolver lookups (eResource page) ----------
-- verify.html can't read Alma directly (browsers block cross-site reads), so it
-- calls this through ILLiad's WebView2 bridge:
--   atlasAddon.ExecuteAddonFunction("AlmaFetch", url, timeoutMs)
-- Only link resolver addresses are allowed:
--   https://<something>.alma.exlibrisgroup.com/view/uresolver/...
--   https://<your Primo server>/view/uresolver/...   (from CatalogSearchURL)
--   or anything starting with the AlmaResolverURL setting.
-- Returns "OK\n<body>" or "ERR\n<message>".
local function AlmaAllowed(url)
  if string.match(url, "^https://[%w%-%.]+%.alma%.exlibrisgroup%.com/view/uresolver/") then return true end
  local primo = string.match(tostring(settings.CatalogSearchURL or ""), "^(https://[^/]+)/")
  if primo ~= nil and string.sub(url, 1, string.len(primo) + 16) == primo .. "/view/uresolver/" then return true end
  local base = tostring(settings.AlmaResolverURL or "")
  base = string.gsub(base, "%?.*$", "")
  return base ~= "" and string.match(base, "^https://") ~= nil and string.sub(url, 1, string.len(base)) == base
end

function AlmaFetch(url, timeoutMs)
  local ok, result = pcall(function()
    url = tostring(url or "")
    if not AlmaAllowed(url) then
      return "ERR\nAddress not allowed: only Alma link resolver addresses can be fetched."
    end
    luanet.load_assembly("System")
    local WebRequest = luanet.import_type("System.Net.WebRequest")
    local StreamReader = luanet.import_type("System.IO.StreamReader")
    local req = WebRequest.Create(url)
    req.Timeout = tonumber(timeoutMs) or 10000
    local resp = req:GetResponse()
    local reader = StreamReader(resp:GetResponseStream())
    local body = reader:ReadToEnd()
    reader:Close()
    resp:Close()
    return "OK\n" .. tostring(body)
  end)
  if ok then return result end
  local msg = ErrorText(result)
  Log("Alma fetch failed: " .. msg)
  return "ERR\n" .. msg
end

-- ---------- Fetch PDF (eResource page) ----------
-- Called from verify.html's Fetch PDF button through the WebView2 bridge:
--   atlasAddon.ExecuteAddonFunction("FetchPdf", tn, doi, oaUrl)
-- Runs on this PC, so campus IP authentication applies. One article per click.
--   1. Try the free open-access PDF (oaUrl), if the page found one.
--   2. Otherwise follow the DOI to the publisher's article page and read the
--      PDF address publishers list for indexing (citation_pdf_url).
--   3. Check the download really is a PDF, then save it as <TN>.pdf in the
--      PdfSaveFolder setting. Existing files are never overwritten (<TN>-2.pdf...).
-- Returns "OK\npath\nbytes\nsource host\npage title\npage DOI"
--      or "ERR\nmessage\npublisher page address".

local PDF_MAX_BYTES = 150 * 1024 * 1024
local USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) ILLiad-CitationCheck/2.2"

local function HtmlUnescape(s)
  s = tostring(s or "")
  s = string.gsub(s, "&amp;", "&")
  s = string.gsub(s, "&quot;", "\"")
  s = string.gsub(s, "&#39;", "'")
  s = string.gsub(s, "&lt;", "<")
  s = string.gsub(s, "&gt;", ">")
  return s
end

-- Value of <meta name="NAME" content="..."> (attributes in either order)
function MetaContent(html, name)
  for tag in string.gmatch(tostring(html or ""), "<meta[^>]->") do
    local n = string.match(tag, "[%s]name%s*=%s*[\"']([^\"']+)[\"']") or string.match(tag, "[%s]property%s*=%s*[\"']([^\"']+)[\"']")
    if n ~= nil and string.lower(n) == string.lower(name) then
      local c = string.match(tag, "[%s]content%s*=%s*\"([^\"]*)\"") or string.match(tag, "[%s]content%s*=%s*'([^']*)'")
      if c ~= nil and c ~= "" then return HtmlUnescape(c) end
    end
  end
  return nil
end

-- <link rel="alternate" type="application/pdf" href="..."> as a fallback
function PdfLinkTag(html)
  for tag in string.gmatch(tostring(html or ""), "<link[^>]->") do
    if string.find(string.lower(tag), "application/pdf", 1, true) then
      local h = string.match(tag, "href%s*=%s*\"([^\"]+)\"") or string.match(tag, "href%s*=%s*'([^']+)'")
      if h ~= nil then return HtmlUnescape(h) end
    end
  end
  return nil
end

-- Keep transaction numbers safe as file names
function SafeFileStem(tn)
  local s = string.gsub(tostring(tn or ""), "[^%w%-_]", "")
  return s
end

local function PdfFolder()
  local folder = tostring(settings.PdfSaveFolder or "")
  if folder == "" then
    local Env = luanet.import_type("System.Environment")
    local Special = luanet.import_type("System.Environment+SpecialFolder")
    folder = Env.GetFolderPath(Special.MyDocuments) .. "\\ILL PDFs"
  end
  return folder
end

-- GET a URL with a shared cookie jar. Returns response object (caller closes) or raises.
local function HttpGet(url, cookies, referer, accept)
  local WebRequest = luanet.import_type("System.Net.WebRequest")
  local req = WebRequest.Create(url)
  req.Timeout = 30000
  pcall(function() req.AllowAutoRedirect = true end)
  pcall(function() req.MaximumAutomaticRedirections = 10 end)
  pcall(function() req.UserAgent = USER_AGENT end)
  pcall(function() req.Accept = accept or "*/*" end)
  pcall(function() req.CookieContainer = cookies end)
  if referer ~= nil then pcall(function() req.Referer = referer end) end
  return req:GetResponse()
end

local function ReadText(resp)
  local StreamReader = luanet.import_type("System.IO.StreamReader")
  local reader = StreamReader(resp:GetResponseStream())
  local text = reader:ReadToEnd()
  reader:Close()
  return tostring(text)
end

-- Download a URL and return the bytes if it is a real PDF, else nil + reason
-- The download stays in a .NET MemoryStream the whole time: ILLiad's Lua engine
-- can't pass raw byte arrays back into .NET methods reliably.
local function StartsLikePdf(ms)
  -- "%PDF" (bytes 37 80 68 70), allowing a little leading whitespace or junk
  ms.Position = 0
  local window = {}
  for i = 1, 1024 do
    local b = tonumber(ms:ReadByte())
    if b == nil or b < 0 then break end
    window[#window + 1] = b
    local n = #window
    if n >= 4 and window[n-3] == 37 and window[n-2] == 80 and window[n-1] == 68 and window[n] == 70 then
      ms.Position = 0
      return true
    end
  end
  ms.Position = 0
  return false
end

-- A bot check instead of content: Amazon CloudFront/WAF answers non-browser
-- requests with status 202 and an empty body (De Gruyter Brill does this);
-- Cloudflare marks its challenges with a "cf-mitigated" header.
-- Only a real browser can pass these, so Fetch PDF offers the PDF Preview tab instead.
function IsBotCheck(resp, length)
  local waf, cf, status = "", "", ""
  pcall(function() waf = tostring(resp.Headers:Get("x-amzn-waf-action") or "") end)
  pcall(function() cf = tostring(resp.Headers:Get("cf-mitigated") or "") end)
  pcall(function() status = tostring(resp.StatusCode) end)
  if waf ~= "" and waf ~= "nil" then return true end
  if string.lower(cf) == "challenge" then return true end
  return (status == "Accepted" or status == "202") and (tonumber(length) or 0) < 1000
end
local BOT_CHECK = "BOTCHECK"

-- Download a URL; returns the MemoryStream if it is a real PDF, else nil + reason
local function DownloadPdf(url, cookies, referer)
  local MemoryStream = luanet.import_type("System.IO.MemoryStream")
  local resp = HttpGet(url, cookies, referer, "application/pdf,*/*")
  local ms = MemoryStream()
  local stream = resp:GetResponseStream()
  stream:CopyTo(ms)
  stream:Close()
  local finalUrl = tostring(resp.ResponseUri.AbsoluteUri)
  local length = tonumber(ms.Length) or 0
  local blocked = IsBotCheck(resp, length)
  resp:Close()
  if blocked and length < 1000 then ms:Close(); return nil, BOT_CHECK, finalUrl end
  if length < 1000 then ms:Close(); return nil, "the file was empty or too small", finalUrl end
  if length > PDF_MAX_BYTES then ms:Close(); return nil, "the file was larger than 150 MB", finalUrl end
  if not StartsLikePdf(ms) then
    ms:Close()
    return nil, "the site returned a web page instead of a PDF (often a login or 'verify you are human' check)", finalUrl
  end
  if IsPreviewPdfUrl(finalUrl) then
    -- Brill sends the short preview instead when it doesn't see full-text access
    ms:Close()
    return nil, "the site sent only its free preview pages, not the full text (it may not see Bowdoin's access for this item)", finalUrl
  end
  return ms, length, finalUrl
end

-- ---------- Review before saving ----------
-- Fetched PDFs first go to a review folder (Windows temp\ILLCitationCheck).
-- verify.html shows the PDF; staff then click Save (ApprovePdf -> <TN>.pdf in
-- PdfSaveFolder) or Discard (DiscardPdf). Nothing reaches PdfSaveFolder unseen.

local reviewCounter = 0

local function ReviewOn()
  return settings.ReviewPdfBeforeSave == nil or SettingIsTrue(settings.ReviewPdfBeforeSave)
end

local function ReviewFolder()
  local Path = luanet.import_type("System.IO.Path")
  return tostring(Path.Combine(Path.GetTempPath(), "ILLCitationCheck"))
end

-- Only files inside the review folder may be approved, discarded or previewed
local function InReviewFolder(path)
  local okP, full = pcall(function()
    local Path = luanet.import_type("System.IO.Path")
    return string.lower(tostring(Path.GetFullPath(tostring(path or ""))))
  end)
  if not okP then return false end
  local root = string.lower(ReviewFolder())
  return string.sub(full, 1, string.len(root) + 1) == root .. "\\" or string.sub(full, 1, string.len(root) + 1) == root .. "/"
end

-- Remove review files older than two days (left behind when a request was closed unreviewed)
local function CleanReviewFolder()
  pcall(function()
    local DirectoryInfo = luanet.import_type("System.IO.DirectoryInfo")
    local DateTime = luanet.import_type("System.DateTime")
    local dir = DirectoryInfo(ReviewFolder())
    if not dir.Exists then return end
    local cutoff = tonumber(DateTime.UtcNow.Ticks) - 2 * 24 * 3600 * 10000000
    local files = dir:GetFiles("*.pdf")
    for i = 0, files.Length - 1 do
      local f = files[i]
      if tonumber(f.LastWriteTimeUtc.Ticks) < cutoff then pcall(function() f:Delete() end) end
    end
  end)
end

-- Next free name in the save folder: <TN>.pdf, <TN>-2.pdf, ...
local function FinalPdfPath(tn)
  local Directory = luanet.import_type("System.IO.Directory")
  local File = luanet.import_type("System.IO.File")
  local Path = luanet.import_type("System.IO.Path")
  local folder = PdfFolder()
  Directory.CreateDirectory(folder)
  local stem = SafeFileStem(tn)
  local path = Path.Combine(folder, stem .. ".pdf")
  local n = 2
  while File.Exists(path) do
    path = Path.Combine(folder, stem .. "-" .. n .. ".pdf")
    n = n + 1
  end
  return tostring(path)
end

-- Save (move) a reviewed PDF as <TN>.pdf. Returns "OK\n<final path>" or "ERR\n<message>".
function ApprovePdf(staged, tn)
  local ok, result = pcall(function()
    if not InReviewFolder(staged) then return "ERR\nThat file isn't in the review folder." end
    if SafeFileStem(tn) == "" then return "ERR\nThis request has no transaction number to name the file." end
    local File = luanet.import_type("System.IO.File")
    if not File.Exists(staged) then return "ERR\nThe reviewed file is gone (it may have been discarded already)." end
    local dest = FinalPdfPath(tn)
    File.Move(staged, dest)
    Log("PDF approved and saved: " .. dest)
    return "OK\n" .. dest
  end)
  if ok then return result end
  return "ERR\n" .. string.gsub(ErrorText(result), "[\r\n]+", " ")
end

-- Delete a PDF that failed review. Returns "OK" or "ERR\n<message>".
function DiscardPdf(staged)
  local ok, result = pcall(function()
    if not InReviewFolder(staged) then return "ERR\nThat file isn't in the review folder." end
    local File = luanet.import_type("System.IO.File")
    if File.Exists(staged) then File.Delete(staged) end
    Log("PDF discarded: " .. tostring(staged))
    return "OK"
  end)
  if ok then return result end
  return "ERR\n" .. string.gsub(ErrorText(result), "[\r\n]+", " ")
end

-- Show a review file in the "PDF Preview" tab (same method as the ILLiad PDF Viewer addon)
function PreviewPdf(staged)
  local ok, result = pcall(function()
    if not InReviewFolder(staged) then return "ERR\nThat file isn't in the review folder." end
    if pdfPreview.browser == nil then return "ERR\nThe PDF Preview tab isn't available on this request." end
    pdfPreview.browser:Navigate("file:///" .. PathEncode(staged))
    return "OK"
  end)
  if ok then return result end
  return "ERR\n" .. string.gsub(ErrorText(result), "[\r\n]+", " ")
end

-- Hand a review file to verify.html as base64 so it can read the first page's
-- text and compare it with the citation. The bytes stay in .NET streams
-- (FileStream -> base64 transform -> text), never in Lua.
-- Returns "OK\n<base64>" or "ERR\n<message>".
local READ_PDF_LIMIT = 60 * 1024 * 1024
function ReadPdf(staged)
  local ok, result = pcall(function()
    if not InReviewFolder(staged) then return "ERR\nThat file isn't in the review folder." end
    local File = luanet.import_type("System.IO.File")
    local FileInfo = luanet.import_type("System.IO.FileInfo")
    if not File.Exists(staged) then return "ERR\nThe file is gone (it may have been discarded already)." end
    if tonumber(FileInfo(staged).Length) > READ_PDF_LIMIT then return "ERR\nthe PDF is too large to check automatically" end
    local CryptoStream = luanet.import_type("System.Security.Cryptography.CryptoStream")
    local CryptoStreamMode = luanet.import_type("System.Security.Cryptography.CryptoStreamMode")
    local ToBase64Transform = luanet.import_type("System.Security.Cryptography.ToBase64Transform")
    local StreamReader = luanet.import_type("System.IO.StreamReader")
    local fs = File.OpenRead(staged)
    local text
    local okR, err = pcall(function()
      local cs = CryptoStream(fs, ToBase64Transform(), CryptoStreamMode.Read)
      local reader = StreamReader(cs)
      text = reader:ReadToEnd()
      reader:Close()
    end)
    pcall(function() fs:Close() end)
    if not okR then error(err, 0) end
    return "OK\n" .. tostring(text)
  end)
  if ok then return result end
  return "ERR\n" .. string.gsub(ErrorText(result), "[\r\n]+", " ")
end

local function SavePdf(ms, tn)
  local Directory = luanet.import_type("System.IO.Directory")
  local File = luanet.import_type("System.IO.File")
  local Path = luanet.import_type("System.IO.Path")
  local DateTime = luanet.import_type("System.DateTime")
  local path
  if ReviewOn() then
    -- held for review: <TN>-<time>.pdf in the review folder
    Directory.CreateDirectory(ReviewFolder())
    reviewCounter = reviewCounter + 1
    local stamp = string.format("%.0f", tonumber(DateTime.UtcNow.Ticks) or 0) .. "-" .. reviewCounter
    path = tostring(Path.Combine(ReviewFolder(), SafeFileStem(tn) .. "-" .. stamp .. ".pdf"))
  else
    path = FinalPdfPath(tn)
  end
  local fs = File.Create(path)
  local ok, err = pcall(function() ms:WriteTo(fs) end)
  fs:Close()
  ms:Close()
  if not ok then error(err, 0) end
  return tostring(path)
end

-- Is <TN>.pdf already in the save folder? Returns its path, or "" if not.
-- Used before an automatic fetch so reopening a request doesn't download it again.
function PdfExists(tn)
  local ok, result = pcall(function()
    local stem = SafeFileStem(tn)
    if stem == "" then return "" end
    luanet.load_assembly("System")
    local File = luanet.import_type("System.IO.File")
    local Path = luanet.import_type("System.IO.Path")
    local path = Path.Combine(PdfFolder(), stem .. ".pdf")
    if File.Exists(path) then return tostring(path) end
    return ""
  end)
  if ok then return result end
  return ""
end

-- ---------- Site rules ----------
-- Brill: the full text is at /downloadpdf/..., the address behind the "Download PDF"
-- button. Brill's article pages list /previewpdf/... (only the first page or two)
-- as their PDF, so that address is never used: it is swapped for /downloadpdf/.
--   https://brill.com/view/journals/<j>/<v>/<i>/article-p27_3.xml -> https://brill.com/downloadpdf/journals/<j>/<v>/<i>/article-p27_3.pdf
--   https://brill.com/display/book/<ISBN>/<ID>.xml                 -> https://brill.com/downloadpdf/book/<ISBN>/<ID>.pdf
--   https://brill.com/previewpdf/journals/...                       -> https://brill.com/downloadpdf/journals/...
-- Returns the full-text addresses to try (the .pdf form, then the .xml form), or nil.
function IsPreviewPdfUrl(u)
  return string.find(string.lower(tostring(u or "")), "/previewpdf/", 1, true) ~= nil
end

function BrillPdfUrls(url)
  url = tostring(url or "")
  local base, path = string.match(url, "^(https?://[%w%.%-]*brill%.com)(/[^?#]*)")
  if base == nil then return nil end
  local prev = string.match(path, "^/previewpdf(/.+)$")
  if prev ~= nil then path = "/downloadpdf" .. prev end
  local rest = string.match(path, "^/downloadpdf(/.+)%.pdf$") or string.match(path, "^/downloadpdf(/.+)%.xml$")
    or string.match(path, "^/display(/.+)%.xml$") or string.match(path, "^/view(/.+)%.xml$")
  if rest == nil then return nil end
  return { base .. "/downloadpdf" .. rest .. ".pdf", base .. "/downloadpdf" .. rest .. ".xml" }
end

function BrillPdfUrl(url)
  local list = BrillPdfUrls(url)
  return list and list[1] or nil
end

-- The "Download PDF" button's address on a Brill page, if the page has one
function BrillButtonLink(html, pageUrl)
  local Uri = luanet.import_type("System.Uri")
  for h in string.gmatch(tostring(html or ""), "href%s*=%s*[\"']([^\"']*/downloadpdf/[^\"']*)[\"']") do
    local okU, abs = pcall(function() return tostring(Uri(Uri(pageUrl), HtmlUnescape(h)).AbsoluteUri) end)
    if okU and abs ~= nil and not IsPreviewPdfUrl(abs) then return abs end
  end
  return nil
end

-- PDF addresses to try for an article page, best first, each with its route name.
-- Brill: the "Download PDF" button, then the full-text pattern, then a listed
-- PDF only if it isn't a preview. Elsewhere: the listed PDF, then site rules.
function PagePdfCandidates(html, pageUrl, doi)
  local Uri = luanet.import_type("System.Uri")
  local out, seen = {}, {}
  local function add(u, route)
    if u ~= nil and u ~= false and not seen[u] and not IsPreviewPdfUrl(u) then seen[u] = true; table.insert(out, { url = u, route = route }) end
  end
  local listed = MetaContent(html, "citation_pdf_url") or PdfLinkTag(html)
  if listed ~= nil then
    local okU, abs = pcall(function() return tostring(Uri(Uri(pageUrl), listed).AbsoluteUri) end)
    listed = okU and abs or nil
  end
  local brill = BrillPdfUrls(pageUrl)
  if brill ~= nil or (listed ~= nil and BrillPdfUrls(listed) ~= nil) then
    add(BrillButtonLink(html, pageUrl), "pagerule")
    for _, u in ipairs(brill or {}) do add(u, "pagerule") end
    if listed ~= nil then
      if IsPreviewPdfUrl(listed) then for _, u in ipairs(BrillPdfUrls(listed) or {}) do add(u, "page") end
      else add(listed, "page") end
    end
  else
    add(listed, "page")
    add(DegruyterPdfUrl(pageUrl, doi), "pagerule")
  end
  return out, listed
end

-- De Gruyter Brill (degruyterbrill.com, formerly degruyter.com): pages and PDFs share one pattern
--   https://www.degruyterbrill.com/document/doi/<DOI>/html  ->  .../document/doi/<DOI>/pdf
-- It hosts many publishers' DOIs (De Gruyter 10.1515, Brill 10.1163, Cornell 10.7591, Chicago 10.7208 ...),
-- so the rule goes by the site the DOI points to, not by the DOI prefix.
function DegruyterPdfUrl(url, doi)
  url = tostring(url or "")
  local base = string.match(url, "^(https?://[%w%.%-]*degruyterbrill%.com)") or string.match(url, "^(https?://[%w%.%-]*degruyter%.com)")
  if base == nil then return nil end
  local d = string.match(url, "/document/doi/(10%.[^?#]-)/[%a]+$") or string.match(url, "/document/doi/(10%.[^?#]-)/[%a]+[?#]") or tostring(doi or "")
  if not string.match(d, "^10%.%d+/") then return nil end
  return base .. "/document/doi/" .. d .. "/pdf"
end

-- Where a DOI points, asked from doi.org's own API (doesn't load the publisher's page)
local function DoiTarget(doi)
  local okR, resp = pcall(HttpGet, "https://doi.org/api/handles/" .. doi .. "?type=URL", nil, nil, "application/json")
  if not okR or resp == nil then return nil end
  local body = ReadText(resp)
  resp:Close()
  local url = string.match(body, '"type"%s*:%s*"URL".-"value"%s*:%s*"([^"]+)"')
  if url ~= nil then url = string.gsub(url, "\\/", "/") end
  return url
end

local function HostOf(url)
  return string.match(tostring(url or ""), "^https?://([^/]+)") or tostring(url or "")
end

-- Routes, tried in order (each has a name so "Try again" on the page can skip it):
--   free      free open-access copy
--   site      site rule (Brill, De Gruyter Brill) for where the DOI points
--   doi       the DOI link itself is a PDF
--   page      the PDF address listed on the publisher's article page
--   pagerule  site rule applied to the article page's address
-- skip: comma-separated route names to leave out (sent by "Try again").
-- ---------- Bowdoin access links (Alma link resolver) ----------
-- verify.html asks Alma's link resolver which online services cover the item
-- and passes the verified ones (in Alma's order) to FetchPdf as
-- "name<TAB>url" lines. Each link usually redirects from Alma to the
-- platform's article page; Fetch PDF follows it and takes the PDF from there.
local function UrlDecode(s)
  s = string.gsub(tostring(s or ""), "%+", " ")
  return (string.gsub(s, "%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

function AlmaLinks(text)
  local out, seen = {}, {}
  for line in string.gmatch(tostring(text or ""), "[^\r\n]+") do
    local name, url = string.match(line, "^(.-)\t(https?://%S+)$")
    if url == nil then url = string.match(line, "^%s*(https?://%S+)%s*$"); name = "" end
    if url ~= nil and not seen[url] then
      seen[url] = true
      name = string.gsub(tostring(name or ""), "^%s+", "")
      table.insert(out, { name = (name ~= "" and name or HostOf(url)), url = url })
    end
  end
  return out
end

-- Redirect pages that use <meta http-equiv="refresh"> or a script instead of HTTP
local function PageRedirect(html)
  local content = string.match(html, '<[Mm][Ee][Tt][Aa][^>]-[Hh][Tt][Tt][Pp]%-[Ee][Qq][Uu][Ii][Vv]%s*=%s*["\']?[Rr]efresh["\']?[^>]-[Cc][Oo][Nn][Tt][Ee][Nn][Tt]%s*=%s*["\']([^"\']+)["\']')
    or string.match(html, '<[Mm][Ee][Tt][Aa][^>]-[Cc][Oo][Nn][Tt][Ee][Nn][Tt]%s*=%s*["\']([^"\']+)["\'][^>]-[Hh][Tt][Tt][Pp]%-[Ee][Qq][Uu][Ii][Vv]%s*=%s*["\']?[Rr]efresh')
  local target = content and string.match(content, "[Uu][Rr][Ll]%s*=%s*'?([^']+)'?")
  if target == nil and string.len(html) < 20000 then
    target = string.match(html, "location%.replace%(%s*[\"']([^\"']+)[\"']") or string.match(html, "location%.href%s*=%s*[\"']([^\"']+)[\"']")
      or string.match(html, "window%.location%s*=%s*[\"']([^\"']+)[\"']")
  end
  if target ~= nil then target = string.gsub(target, "&amp;", "&") end
  return target
end

-- Returns "OK\npath\nbytes\nsource\npage title\npage DOI\nroute" or "ERR\nmessage\npage".
function FetchPdf(tn, doi, oaUrl, skip, title, author, almaText)
  local landing = ""
  local botUrl = nil      -- first PDF address that only a real browser can open
  local ok, result = pcall(function()
    tn = tostring(tn or ""); doi = tostring(doi or ""); oaUrl = tostring(oaUrl or "")
    if SafeFileStem(tn) == "" then return "ERR\nThis request has no transaction number to name the file.\n" end
    if doi ~= "" and not string.match(doi, "^10%.%d+/") then doi = "" end
    if doi ~= "" then landing = "https://doi.org/" .. doi end
    local almaLinks = AlmaLinks(almaText)
    if landing == "" and #almaLinks > 0 then landing = almaLinks[1].url end
    local skipped = {}
    for name in string.gmatch(tostring(skip or ""), "[^,%s]+") do skipped[name] = true end
    luanet.load_assembly("System")
    local CookieContainer = luanet.import_type("System.Net.CookieContainer")
    local Uri = luanet.import_type("System.Uri")
    local cookies = CookieContainer()
    local reasons = {}
    local attempted = 0
    local lastError = nil

    local function saved(ms, size, finalUrl, label, route, pageTitle, pageDoi)
      local path = SavePdf(ms, tn)
      Log("PDF fetched via " .. route .. " from " .. HostOf(finalUrl) .. ": " .. path)
      return "OK\n" .. path .. "\n" .. tostring(size) .. "\n" .. HostOf(finalUrl) .. label .. "\n" ..
             string.gsub(tostring(pageTitle or ""), "[\r\n]+", " ") .. "\n" .. tostring(pageDoi or "") .. "\n" .. route
    end
    local function attempt(url, referer)
      if IsPreviewPdfUrl(url) then
        local full = BrillPdfUrl(url)
        if full == nil then return nil, "only a preview PDF was offered" end
        url = full
      end
      attempted = attempted + 1
      local okD, ms, sizeOrWhy, finalUrl = pcall(DownloadPdf, url, cookies, referer)
      if okD and ms ~= nil then return ms, sizeOrWhy, finalUrl end
      if okD and sizeOrWhy == BOT_CHECK then
        botUrl = botUrl or url
        return nil, HostOf(url) .. " only serves it to a regular web browser (bot check)"
      end
      return nil, (okD and tostring(sizeOrWhy) or ErrorText(ms))
    end

    -- Follow one link to a PDF: the link itself if it is a PDF, otherwise the
    -- PDF its page lists, or a site rule. Follows meta-refresh/script redirects
    -- and, for a proxy login link, the address inside it.
    -- Returns the result string, or nil + reason.
    local function tryLink(link, label, route)
      local why = nil
      local url = link
      for hop = 1, 3 do
        local direct = BrillPdfUrl(url) or DegruyterPdfUrl(url, doi)
        if direct ~= nil then
          local ms, size, finalUrl = attempt(direct, url)
          if ms ~= nil then return saved(ms, size, finalUrl, label, route, "", "") end
          why = HostOf(direct) .. ": " .. tostring(size)
        end
        local resp = HttpGet(url, cookies, nil, "text/html,application/xhtml+xml,application/pdf,*/*")
        local pageUrl = tostring(resp.ResponseUri.AbsoluteUri)
        local ctype = string.lower(tostring(resp.ContentType or ""))
        if string.find(ctype, "application/pdf", 1, true) then
          resp:Close()
          local ms, size, finalUrl = attempt(pageUrl, nil)
          if ms ~= nil then return saved(ms, size, finalUrl, label, route, "", "") end
          return nil, HostOf(pageUrl) .. ": " .. tostring(size)
        end
        local html = ReadText(resp)
        local blocked = IsBotCheck(resp, string.len(html))
        resp:Close()
        if blocked then
          botUrl = botUrl or DegruyterPdfUrl(pageUrl, doi) or BrillPdfUrl(pageUrl) or pageUrl
          return nil, HostOf(pageUrl) .. " only serves its pages to a regular web browser (bot check)"
        end
        local cands = PagePdfCandidates(html, pageUrl, doi)
        if #cands == 0 then
          -- not an article page yet: an intermediate redirect page, or a proxy login
          local nextUrl = PageRedirect(html)
          if nextUrl == nil then
            local inner = string.match(pageUrl, "[?&]q?url=(https?[^&]+)") or string.match(pageUrl, "[?&]q?url=(https?%%3[Aa][^&]+)")
            if inner ~= nil then nextUrl = UrlDecode(inner) end
          end
          if nextUrl == nil or hop == 3 then
            return nil, why or (HostOf(pageUrl) .. " doesn't list a PDF on its page")
          end
          url = tostring(Uri(Uri(pageUrl), nextUrl).AbsoluteUri)
        else
          local pageTitle = MetaContent(html, "citation_title") or MetaContent(html, "dc.title") or ""
          local pageDoi = MetaContent(html, "citation_doi") or MetaContent(html, "dc.identifier") or ""
          pageDoi = string.gsub(string.gsub(pageDoi, "^doi:", ""), "^https?://[%w%.]*doi%.org/", "")
          for _, c in ipairs(cands) do
            local ms, size, finalUrl = attempt(c.url, pageUrl)
            if ms ~= nil then return saved(ms, size, finalUrl, label, route, pageTitle, pageDoi) end
            why = HostOf(c.url) .. ": " .. tostring(size)
          end
          return nil, why
        end
      end
      return nil, why
    end

    -- 0. Bowdoin's verified online access (Alma link resolver), in Alma's order.
    --    Each link is its own route (alma1, alma2, ...), so Try again moves to the next one.
    for i, a in ipairs(almaLinks) do
      local route = "alma" .. i
      if not skipped[route] and not skipped.alma then
        local okL, res, why = pcall(tryLink, a.url, " (Bowdoin: " .. a.name .. ")", route)
        if okL and res ~= nil then return res end
        table.insert(reasons, a.name .. ": " .. (okL and tostring(why) or string.gsub(ErrorText(res), "[\r\n]+", " ")))
      end
    end

    -- 1. Free open-access copy
    if not skipped.free and string.match(oaUrl, "^https?://") then
      local ms, size, finalUrl = attempt(oaUrl, nil)
      if ms ~= nil then return saved(ms, size, finalUrl, " (free copy)", "free", "", "") end
      table.insert(reasons, "free copy: " .. tostring(size))
    end

    -- 1b. EBSCO (EBSCOhost API), by DOI or title + author
    if not skipped.ebsco and EbscoConfigured() then
      local okE, pdfUrl, rec = pcall(EbscoFindPdf, doi, tostring(title or ""), tostring(author or ""))
      if okE and pdfUrl ~= nil then
        local ms, size, finalUrl = attempt(pdfUrl, nil)
        if ms ~= nil then return saved(ms, size, finalUrl, " (EBSCO)", "ebsco", rec.title, rec.doi or "") end
        table.insert(reasons, "EBSCO: " .. tostring(size))
      elseif okE then
        table.insert(reasons, "EBSCO: " .. tostring(rec))
      else
        Log("EBSCO route: " .. ErrorText(pdfUrl))
        table.insert(reasons, "EBSCO: " .. string.gsub(ErrorText(pdfUrl), "[\r\n]+", " "))
      end
    end

    -- 2. Everything else needs the DOI
    if doi == "" then
      return "ERR\nNo DOI to follow" .. (#reasons > 0 and (" (" .. table.concat(reasons, "; ") .. ")") or "") .. ".\n" .. landing
    end

    -- 2a. Site rules for where the DOI points (doesn't load the publisher's article page)
    local target = DoiTarget(doi)
    if not skipped.site then
      local ruleName, rulePdfs = nil, nil
      if BrillPdfUrls(target) ~= nil then ruleName, rulePdfs = "Brill", BrillPdfUrls(target)
      elseif DegruyterPdfUrl(target, doi) ~= nil then ruleName, rulePdfs = "De Gruyter Brill", { DegruyterPdfUrl(target, doi) } end
      for _, rulePdf in ipairs(rulePdfs or {}) do
        local ms, size, finalUrl = attempt(rulePdf, target)
        if ms ~= nil then return saved(ms, size, finalUrl, " (" .. ruleName .. ")", "site", "", doi) end
        table.insert(reasons, ruleName .. ": " .. tostring(size))
      end
    end

    -- 2b. The DOI link and the publisher's article page
    if not (skipped.doi and skipped.page and skipped.pagerule) then
      local resp = HttpGet(landing, cookies, nil, "text/html,application/xhtml+xml,*/*")
      local pageUrl = tostring(resp.ResponseUri.AbsoluteUri)
      local ctype = string.lower(tostring(resp.ContentType or ""))
      if string.find(ctype, "application/pdf", 1, true) then
        resp:Close()
        if not skipped.doi then
          local ms, size, finalUrl = attempt(pageUrl, nil)
          if ms ~= nil then return saved(ms, size, finalUrl, "", "doi", "", doi) end
          lastError = "The DOI led to a file, but " .. tostring(size) .. ".\n" .. landing
        end
      else
        local html = ReadText(resp)
        local blocked = IsBotCheck(resp, string.len(html))
        resp:Close()
        landing = pageUrl
        if blocked then
          botUrl = botUrl or DegruyterPdfUrl(pageUrl, doi) or BrillPdfUrl(pageUrl) or pageUrl
          lastError = HostOf(pageUrl) .. " only serves its pages to a regular web browser (bot check).\n" .. pageUrl
          html = ""
        end
        local pageTitle = MetaContent(html, "citation_title") or MetaContent(html, "dc.title") or ""
        local pageDoi = MetaContent(html, "citation_doi") or MetaContent(html, "dc.identifier") or ""
        pageDoi = string.gsub(pageDoi, "^doi:", "")
        pageDoi = string.gsub(pageDoi, "^https?://[%w%.]*doi%.org/", "")
        local cands = {}
        if not blocked then cands = PagePdfCandidates(html, pageUrl, doi) end
        for _, c in ipairs(cands) do
          if not skipped[c.route] then
            local ms, size, finalUrl = attempt(c.url, pageUrl)
            if ms ~= nil then return saved(ms, size, finalUrl, "", c.route, pageTitle, pageDoi) end
            lastError = "Couldn't download from " .. HostOf(c.url) .. ": " .. tostring(size) .. ".\n" .. pageUrl
          end
        end
        if #cands == 0 and lastError == nil and not blocked then
          lastError = HostOf(pageUrl) .. " doesn't list a PDF address on its article page, so it needs a manual download.\n" .. pageUrl
        end
      end
    end

    if lastError ~= nil then return "ERR\n" .. lastError end
    if attempted == 0 and next(skipped) ~= nil then
      return "ERR\nThere's no other way to fetch this one automatically.\n" .. landing
    end
    return "ERR\nNo automatic download worked" .. (#reasons > 0 and (" (" .. table.concat(reasons, "; ") .. ")") or "") .. ".\n" .. landing
  end)
  if ok then
    CleanReviewFolder()
    if ReviewOn() and string.sub(tostring(result), 1, 3) == "OK\n" then result = "PENDING\n" .. string.sub(result, 4) end
    if botUrl ~= nil and string.sub(tostring(result), 1, 4) == "ERR\n" then
      -- the publisher only serves the PDF to a real browser: the page offers the PDF Preview tab
      result = "ERR\n" .. HostOf(botUrl) .. " only serves PDFs to a regular web browser, so the background download was blocked by its bot check." ..
               "\n" .. landing .. "\nBROWSER\t" .. botUrl
    end
    return result
  end
  local msg = ErrorText(result)
  Log("Fetch PDF failed: " .. msg)
  if botUrl ~= nil then
    return "ERR\n" .. HostOf(botUrl) .. " only serves PDFs to a regular web browser, so the background download was blocked by its bot check." ..
           "\n" .. landing .. "\nBROWSER\t" .. botUrl
  end
  return "ERR\nThe download failed: " .. string.gsub(msg, "[\r\n]+", " ") .. "\n" .. landing
end

-- ---------- Download through the PDF Preview tab (real browser) ----------
-- For publishers whose bot check blocks background downloads (De Gruyter Brill),
-- verify.html offers "Open in PDF Preview": the PDF address loads in the PDF
-- Preview tab, a real WebView2 (Edge) browser that passes the check like any
-- staff browser and uses Bowdoin's IP access. When staff click the viewer's
-- download button (or the site sends the file as a download), the addon catches
-- that one download and puts it in the review folder under the TN, so it gets
-- the same first-page check and Save as TN.pdf. The addon never clicks
-- anything on the publisher's site; it only opens the address and catches the
-- download staff start. One download per click of the button, for 15 minutes.
local capture = { armed = false, hooked = false, tn = "", started = 0, op = nil, path = nil, source = "" }

local function PreviewCore()
  local core = nil
  pcall(function() core = pdfPreview.browser.WebBrowser.CoreWebView2 end)
  return core
end

local function FileIsPdf(path)
  local ok, yes = pcall(function()
    local File = luanet.import_type("System.IO.File")
    local fs = File.OpenRead(path)
    local window = {}
    local found = false
    for i = 1, 1024 do
      local b = tonumber(fs:ReadByte())
      if b == nil or b < 0 then break end
      window[#window + 1] = b
      local n = #window
      if n >= 4 and window[n-3] == 37 and window[n-2] == 80 and window[n-1] == 68 and window[n] == 70 then found = true; break end
    end
    fs:Close()
    return found
  end)
  return ok and yes == true
end

function OnPreviewDownload(args)
  local ok, err = pcall(function()
    if not capture.armed then return end            -- only the download staff start after "Open in PDF Preview"
    capture.armed = false
    local Directory = luanet.import_type("System.IO.Directory")
    local Path = luanet.import_type("System.IO.Path")
    local DateTime = luanet.import_type("System.DateTime")
    local path
    if ReviewOn() then
      Directory.CreateDirectory(ReviewFolder())
      reviewCounter = reviewCounter + 1
      local stamp = string.format("%.0f", tonumber(DateTime.UtcNow.Ticks) or 0) .. "-" .. reviewCounter
      path = tostring(Path.Combine(ReviewFolder(), SafeFileStem(capture.tn) .. "-" .. stamp .. ".pdf"))
    else
      path = FinalPdfPath(capture.tn)
    end
    args.ResultFilePath = path
    pcall(function() args.Handled = true end)       -- no Edge download bubble
    capture.path = path
    capture.op = args.DownloadOperation
    pcall(function() capture.source = HostOf(tostring(args.DownloadOperation.Uri)) end)
    Log("PDF Preview download caught: " .. path)
  end)
  if not ok then Log("PDF Preview download: " .. ErrorText(err)) end
end

local function HookPreviewDownloads()
  if capture.hooked then return true end
  local core = PreviewCore()
  if core == nil then return false end
  local ok, err = pcall(function()
    core.DownloadStarting:Add(function(sender, args) OnPreviewDownload(args) end)
  end)
  if ok then capture.hooked = true else Log("PDF Preview downloads not hooked: " .. ErrorText(err)) end
  return capture.hooked
end

-- Bridge: open a PDF address in the PDF Preview tab and catch the next download.
-- Returns "OK" or "ERR\nmessage".
function OpenInPreview(url, tn)
  local ok, result = pcall(function()
    url = tostring(url or ""); tn = tostring(tn or "")
    if not string.match(url, "^https?://[%w%-%.]+") then return "ERR\nThat isn't a web address." end
    if SafeFileStem(tn) == "" then return "ERR\nThis request has no transaction number to name the file." end
    if pdfPreview.browser == nil then return "ERR\nThe PDF Preview tab isn't available on this request (it needs ILLiad's WebView2 browser)." end
    capture.armed = true; capture.tn = tn; capture.started = os.time()
    capture.op = nil; capture.path = nil; capture.source = HostOf(url)
    pdfPreview.browser:Navigate(url)
    HookPreviewDownloads()                          -- may not be ready yet; PreviewCaptureStatus retries
    return "OK"
  end)
  if ok then return result end
  return "ERR\n" .. string.gsub(ErrorText(result), "[\r\n]+", " ")
end

-- Bridge: polled by verify.html after OpenInPreview.
--   "WAIT\n<what is happening>"  |  "PENDING/OK\npath\nbytes\nsource\n\n\nbrowser"  |  "ERR\nmessage"
function PreviewCaptureStatus()
  local ok, result = pcall(function()
    if not HookPreviewDownloads() then return "WAIT\nstarting the PDF Preview tab" end
    if capture.op == nil then
      if not capture.armed then return "ERR\nNothing is waiting for a download. Click Open in PDF Preview again." end
      if os.time() - capture.started > 900 then
        capture.armed = false
        return "ERR\nNo download within 15 minutes, so the addon stopped waiting. Click Open in PDF Preview to try again."
      end
      return "WAIT\nwaiting for you to download the PDF in the PDF Preview tab"
    end
    local state = tostring(capture.op.State)
    if string.find(state, "Interrupted", 1, true) then
      local why = ""; pcall(function() why = tostring(capture.op.InterruptReason) end)
      capture.op = nil
      return "ERR\nThe download in the PDF Preview tab stopped (" .. why .. ")."
    end
    if not string.find(state, "Completed", 1, true) then return "WAIT\ndownloading" end
    local path = capture.path
    capture.op = nil
    if not FileIsPdf(path) then
      pcall(function() luanet.import_type("System.IO.File").Delete(path) end)
      return "ERR\nThe file downloaded in the PDF Preview tab isn't a PDF, so it was removed."
    end
    local size = 0
    pcall(function() size = tonumber(luanet.import_type("System.IO.FileInfo")(path).Length) or 0 end)
    return (ReviewOn() and "PENDING" or "OK") .. "\n" .. path .. "\n" .. tostring(size) .. "\n" .. capture.source .. " (PDF Preview tab)\n\n\nbrowser"
  end)
  if ok then return result end
  return "ERR\n" .. string.gsub(ErrorText(result), "[\r\n]+", " ")
end

-- Bridge: stop waiting (Try again, or the card was replaced)
function CancelPreviewCapture()
  capture.armed = false
  return "OK"
end

-- ---------- EBSCO: EBSCOhost API (EIT) ----------
-- A licensed route for Fetch PDF. Signs in with the EIT profile
-- (customerID.groupID.profileID) and password, lists the profile's databases
-- (Info), searches them by DOI and then by title + author (Search), and if
-- the matching record lists a PDF link, downloads it.
-- Off until EbscoProfile and EbscoPassword are filled in.
local EIT_BASE = "https://eit.ebscohost.com/Services/SearchService.asmx"
local eit = { dbs = nil }

function EbscoConfigured()
  return settings.EbscoProfile ~= "" and settings.EbscoPassword ~= ""
end

-- GET one EIT address and return the response text. On an HTTP error, EBSCO's
-- own explanation from the response body is included in the message.
local function EitGet(method, params)
  local url = EIT_BASE .. "/" .. method .. "?prof=" .. UrlEncode(settings.EbscoProfile) .. "&pwd=" .. UrlEncode(settings.EbscoPassword)
  if params ~= nil and params ~= "" then url = url .. "&" .. params end
  local WebRequest = luanet.import_type("System.Net.WebRequest")
  local req = WebRequest.Create(url)
  req.Timeout = 30000
  pcall(function() req.UserAgent = USER_AGENT end)
  pcall(function() req.Accept = "application/xml, text/xml" end)
  local okR, resp = pcall(function() return req:GetResponse() end)
  if not okR then
    local detail = ""
    pcall(function()
      local r = nil
      pcall(function() r = resp.Response end)
      if r == nil then pcall(function() r = resp.InnerException.Response end) end
      if r ~= nil then detail = ReadText(r) end
    end)
    detail = string.gsub(string.gsub(detail, "<[^>]+>", " "), "%s+", " ")
    -- the address holds the password, so it is never put in the message
    error("EBSCO: " .. (detail ~= " " and detail ~= "" and string.sub(detail, 1, 300) or string.gsub(ErrorText(resp), "https?://%S+", "")), 0)
  end
  local text = ReadText(resp)
  resp:Close()
  return text
end

-- XML helpers (namespace-agnostic XPath)
local function XmlDoc(text)
  luanet.load_assembly("System.Xml")
  local XmlDocument = luanet.import_type("System.Xml.XmlDocument")
  local doc = XmlDocument()
  doc:LoadXml(text)
  return doc
end
local function NodeText(node, xpath)
  local ok, v = pcall(function()
    local n = node:SelectSingleNode(xpath)
    if n == nil then return nil end
    return tostring(n.InnerText)
  end)
  if ok and v ~= nil and v ~= "" then return v end
  return nil
end

local STOP = { a=1, an=1, the=1, of=1, ["and"]=1, ["in"]=1, on=1, ["for"]=1, to=1, with=1, from=1, by=1, at=1, as=1, ["or"]=1, ["not"]=1 }
local function Words(s)
  local out = {}
  for w in string.gmatch(string.lower(tostring(s or "")), "%w+") do
    if not STOP[w] and string.len(w) > 1 then table.insert(out, w) end
  end
  return out
end
-- Share of the requested title's words found in the record's title (0..1)
local function TitleOverlap(want, got)
  local W, G = Words(want), {}
  if #W == 0 then return 0 end
  for _, w in ipairs(Words(got)) do G[w] = true end
  local hit = 0
  for _, w in ipairs(W) do if G[w] then hit = hit + 1 end end
  return hit / #W
end

-- The profile's database short names (asked once per request form)
function EitDatabases()
  if eit.dbs ~= nil then return eit.dbs end
  local text = EitGet("Info", "")
  local okX, doc = pcall(XmlDoc, text)
  if not okX then error("EBSCO sent back something that isn't XML: " .. string.sub(string.gsub(text, "<[^>]+>", " "), 1, 200), 0) end
  local list, seen = {}, {}
  local nodes = doc:SelectNodes("//*[local-name()='db'][@shortName]")
  for i = 0, nodes.Count - 1 do
    local name = NodeText(nodes:Item(i), "@shortName")
    if name ~= nil and not seen[name] then seen[name] = true; table.insert(list, name) end
  end
  if #list == 0 then
    -- usually a sign-in problem: EBSCO answers with an error message instead of the list
    local msg = string.gsub(string.gsub(text, "<[^>]+>", " "), "%s+", " ")
    error("EBSCO didn't list any databases for this profile. It said: " .. string.sub(msg, 1, 300), 0)
  end
  eit.dbs = list
  return list
end

local LOWER = "translate(local-name(),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')"

-- Records from an EIT search: { dbid, an, title, doi, pdf, fields }
local function EitRecords(text)
  local list = {}
  local doc = XmlDoc(text)
  local nodes = doc:SelectNodes("//*[local-name()='rec']")
  for i = 0, nodes.Count - 1 do
    local r = nodes:Item(i)
    local pdf = NodeText(r, ".//*[" .. LOWER .. "='pdflink']")
    if pdf ~= nil and not string.match(pdf, "^https?://") then pdf = nil end
    -- element names in the record, shown by Test EBSCO if no PDF link is found
    local names, seen = {}, {}
    local all = r:SelectNodes(".//*")
    for j = 0, all.Count - 1 do
      local n = tostring(all:Item(j).LocalName)
      if not seen[n] then seen[n] = true; table.insert(names, n) end
    end
    table.insert(list, {
      dbid = NodeText(r, ".//*[local-name()='header']/@shortDbName"),
      an = NodeText(r, ".//*[local-name()='header']/@uiTerm"),
      title = NodeText(r, ".//*[local-name()='atl']") or NodeText(r, ".//*[local-name()='btl']") or "",
      doi = NodeText(r, ".//*[local-name()='ui'][@type='doi']"),
      pdf = pdf,
      fields = table.concat(names, ", ")
    })
  end
  return list
end

-- EBSCOhost search syntax: TI (word AND word ...) AND AU surname
local function EitTitleQuery(title, author)
  local w = Words(title)
  local keep = {}
  for i = 1, math.min(#w, 8) do keep[i] = w[i] end
  if #keep == 0 then return nil end
  local q = "TI (" .. table.concat(keep, " AND ") .. ")"
  local au = Words(author)[1]
  if au ~= nil then q = q .. " AND AU " .. au end
  return q
end

-- A record counts only if its DOI matches, or its title matches and its DOI doesn't conflict
local function RecordMatches(r, doi, title)
  local doiMatch = doi ~= "" and r.doi ~= nil and string.lower(r.doi) == string.lower(doi)
  local titleMatch = tostring(title or "") ~= "" and TitleOverlap(title, r.title) >= 0.8
  local doiConflict = doi ~= "" and r.doi ~= nil and not doiMatch
  return doiMatch or (titleMatch and not doiConflict)
end

-- Returns pdfUrl, record   or   nil, reason, record-fields (for Test EBSCO)
function EbscoFindPdf(doi, title, author)
  local dbs = EitDatabases()
  local dbParams = {}
  for _, d in ipairs(dbs) do table.insert(dbParams, "db=" .. UrlEncode(d)) end
  local queries = {}
  if doi ~= "" then table.insert(queries, '"' .. doi .. '"') end
  local tq = EitTitleQuery(title, author)
  if tq ~= nil then table.insert(queries, tq) end
  local found, fields = nil, nil
  for _, q in ipairs(queries) do
    local text = EitGet("Search", "query=" .. UrlEncode(q) .. "&" .. table.concat(dbParams, "&") ..
      "&startrec=1&numrec=10&format=detailed&sort=relevance&authType=profile")
    for _, r in ipairs(EitRecords(text)) do
      if RecordMatches(r, doi, title) then
        if r.pdf ~= nil then return r.pdf, r end
        found = r; fields = r.fields
      end
    end
  end
  if found ~= nil then return nil, "found the record (" .. tostring(found.dbid) .. " " .. tostring(found.an) .. "), but EBSCO lists no PDF link for it", fields end
  return nil, "no matching record"
end

-- Ribbon button: checks the EBSCO sign-in and this request, without downloading anything
function TestEbsco()
  local lines = {}
  local ok, err = pcall(function()
    if not EbscoConfigured() then
      table.insert(lines, "EBSCO isn't set up: fill in EbscoProfile and EbscoPassword in the addon settings.")
      return
    end
    eit.dbs = nil
    local dbs = EitDatabases()
    table.insert(lines, "Sign-in: OK (" .. #dbs .. " database" .. (#dbs == 1 and "" or "s") .. ": " ..
      table.concat(dbs, ", ", 1, math.min(#dbs, 12)) .. (#dbs > 12 and ", ..." or "") .. ")")
    local doi = Field("DOI") or ""
    local title = Field("PhotoArticleTitle") or Field("LoanTitle") or ""
    if doi ~= "" or title ~= "" then
      local okF, pdf, rec, fields = pcall(EbscoFindPdf, doi, title, Field("PhotoArticleAuthor") or Field("LoanAuthor") or "")
      if okF and pdf ~= nil then table.insert(lines, "This request: PDF available (" .. tostring(rec.dbid) .. " " .. tostring(rec.an) .. ")")
      elseif okF then
        table.insert(lines, "This request: " .. tostring(rec))
        if fields ~= nil then table.insert(lines, "Record fields: " .. fields) end
      else table.insert(lines, "This request: " .. ErrorText(pdf)) end
    end
  end)
  if not ok then table.insert(lines, "Problem: " .. ErrorText(err)) end
  pcall(function() interfaceMngr:ShowMessage(table.concat(lines, "\r\n"), "EBSCO test") end)
end

-- Builds verify.html#email=...&f_LoanTitle=... and opens it in the tab.
-- Everything goes after "#", so it stays on this computer and is never
-- sent to any web server.
function LoadAgent(waitForClick)
  local ok, err = pcall(function()
    Step("read request fields")
    local parts = {}
    local function add(k, v)
      if v ~= nil and tostring(v) ~= "" then
        table.insert(parts, k .. "=" .. UrlEncode(v))
      end
    end

    add("email", settings.ContactEmail)
    add("catalog", settings.CatalogSearchURL)
    add("resolver", settings.LinkResolverURL)
    add("alma", settings.AlmaResolverURL)
    if settings.AutoFetchPdf == nil or SettingIsTrue(settings.AutoFetchPdf) then add("autopdf", "true") else add("autopdf", "false") end
    if ReviewOn() then add("review", "true") else add("review", "false") end
    if EbscoConfigured() then add("eds", "true") end
    if waitForClick == true then add("auto", "false") else add("auto", "true") end

    Step("detect mode")
    local mode = DetectMode()
    Log("mode: " .. mode .. " (username: " .. tostring(Field("Username")) .. ")")
    add("mode", mode)

    for _, name in ipairs(FIELDS) do
      add("f_" .. name, Field(name))
    end

    Step("build page address")
    local dir = tostring(AddonInfo.Directory)
    local url = "file:///" .. PathEncode(dir) .. "/verify.html#" .. table.concat(parts, "&")

    Step("open verify.html from " .. dir)
    agentForm.Browser:Navigate(url)
    Step("done")
  end)
  if not ok then ShowError("The citation check page could not be opened.", err) end
end
