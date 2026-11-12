/**
 * ILL Strategy Agent - analytics receiver (Google Apps Script)
 *
 * Paste this into the Google Sheet's Extensions > Apps Script, run setup() once,
 * then Deploy > New deployment > Web app (Execute as: Me, Who has access: Anyone).
 * Put the web-app address in the addon's AnalyticsUrl setting and the key that
 * setup() prints in AnalyticsKey.
 *
 * Every PC running the addon sends rows here; the Dashboard tab updates by itself.
 * Rows hold the TN, outcomes, routes and publisher sites only: no titles,
 * authors, DOIs or patron details.
 */

const LOG = 'Log';
const DASH = 'Dashboard';
const COLS = ['Received', 'Time on PC', 'PC', 'Version', 'Event', 'TN', 'Mode', 'Confidence',
              'Outcome', 'Route', 'Site', 'How', 'First-page check', 'Seconds', 'Detail'];

/** Receives rows from the addon: {"key": "...", "rows": [ {...}, ... ]} */
function doPost(e) {
  let body;
  try { body = JSON.parse(e.postData.contents); } catch (err) { return reply('bad request'); }
  const key = PropertiesService.getScriptProperties().getProperty('KEY');
  if (!key || !body || body.key !== key) return reply('bad key');
  const rows = (Array.isArray(body.rows) ? body.rows : []).slice(0, 500).map(r => [
    new Date(), clip(r.time), clip(r.pc), clip(r.version), clip(r.event), clip(r.tn), clip(r.mode),
    clip(r.confidence), clip(r.outcome), clip(r.route), clip(r.host), clip(r.auto), clip(r.check),
    (r.seconds === '' || r.seconds === undefined || isNaN(Number(r.seconds))) ? '' : Number(r.seconds),
    clip(r.detail, 300)
  ]);
  if (!rows.length) return reply('no rows');
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    const sh = logSheet_();
    sh.getRange(sh.getLastRow() + 1, 1, rows.length, COLS.length).setValues(rows);
  } finally {
    lock.releaseLock();
  }
  return reply('ok ' + rows.length);
}

/** A quick check that the web app is deployed: opening its address in a browser shows this. */
function doGet() {
  return reply('ILL Strategy Agent analytics is running.');
}

function reply(text) {
  return ContentService.createTextOutput(text).setMimeType(ContentService.MimeType.TEXT);
}

/** Text only, short, and never treated as a formula. */
function clip(v, n) {
  let s = (v === null || v === undefined) ? '' : String(v);
  s = s.replace(/[\r\n\t]+/g, ' ').slice(0, n || 120);
  if (/^[=+\-@]/.test(s)) s = "'" + s;
  return s;
}

function logSheet_() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sh = ss.getSheetByName(LOG);
  if (!sh) sh = ss.insertSheet(LOG);
  if (sh.getLastRow() === 0) {
    sh.getRange(1, 1, 1, COLS.length).setValues([COLS]).setFontWeight('bold');
    sh.setFrozenRows(1);
    sh.getRange('A:A').setNumberFormat('yyyy-mm-dd hh:mm');
  }
  return sh;
}

/**
 * Run once from the Apps Script editor (select setup, click Run).
 * Creates the Log and Dashboard tabs and the key. The key appears in the
 * Execution log at the bottom of the editor: copy it into AnalyticsKey.
 * Running it again rebuilds the Dashboard and keeps the same key and data.
 */
function setup() {
  const props = PropertiesService.getScriptProperties();
  let key = props.getProperty('KEY');
  if (!key) { key = Utilities.getUuid(); props.setProperty('KEY', key); }
  logSheet_();
  buildDashboard_();
  Logger.log('AnalyticsKey for the addon settings: ' + key);
}

/** Make a new key (old PCs stop being accepted until they get the new one). */
function newKey() {
  const key = Utilities.getUuid();
  PropertiesService.getScriptProperties().setProperty('KEY', key);
  Logger.log('New AnalyticsKey: ' + key);
}

function buildDashboard_() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let d = ss.getSheetByName(DASH);
  if (!d) d = ss.insertSheet(DASH, 0);
  d.clear();

  // Log columns
  const E = 'Log!$E$2:$E', F = 'Log!$F$2:$F', G = 'Log!$G$2:$G', H = 'Log!$H$2:$H', I = 'Log!$I$2:$I',
        L = 'Log!$L$2:$L', M = 'Log!$M$2:$M', N = 'Log!$N$2:$N', A = 'Log!$A$2:$A';
  const recent = ',' + A + ',">="&(TODAY()-30)';      // extra condition for the last-30-days column
  const cnt = (cond, r) => 'COUNTIFS(' + cond + (r ? recent : '') + ')';
  const uniq = (cond, r) => 'COUNTUNIQUEIFS(' + F + ',' + cond + (r ? recent : '') + ')';
  const pct = (num, den) => '=IFERROR(' + num + '/' + den + ',"")';

  // [label, all-time formula, last-30-days formula, format]   format: n = number, p = percent, s = seconds
  const rows = [
    ['CITATION CHECKS'],
    ['Requests checked', '=' + uniq(E + ',"check"'), '=' + uniq(E + ',"check"', true), 'n'],
    ['   eResource (Lending)', '=' + uniq(E + ',"check",' + G + ',"eresource"'), '=' + uniq(E + ',"check",' + G + ',"eresource"', true), 'n'],
    ['   Borrowing', '=' + uniq(E + ',"check",' + G + ',"borrowing"'), '=' + uniq(E + ',"check",' + G + ',"borrowing"', true), 'n'],
    ['Citations verified (High or Medium)', pct(cnt(E + ',"check",' + I + ',"verified"'), cnt(E + ',"check"')), pct(cnt(E + ',"check",' + I + ',"verified"', true), cnt(E + ',"check"', true)), 'p'],
    ['   High confidence', pct(cnt(E + ',"check",' + H + ',"High"'), cnt(E + ',"check"')), pct(cnt(E + ',"check",' + H + ',"High"', true), cnt(E + ',"check"', true)), 'p'],
    ['   Medium', pct(cnt(E + ',"check",' + H + ',"Medium"'), cnt(E + ',"check"')), pct(cnt(E + ',"check",' + H + ',"Medium"', true), cnt(E + ',"check"', true)), 'p'],
    ['   Low', pct(cnt(E + ',"check",' + H + ',"Low"'), cnt(E + ',"check"')), pct(cnt(E + ',"check",' + H + ',"Low"', true), cnt(E + ',"check"', true)), 'p'],
    ['   None (no match found)', pct(cnt(E + ',"check",' + H + ',"None"'), cnt(E + ',"check"')), pct(cnt(E + ',"check",' + H + ',"None"', true), cnt(E + ',"check"', true)), 'p'],
    [''],
    ['PDF FETCHING (eResource)'],
    ['Requests with a PDF saved', '=' + uniq(E + ',"saved"'), '=' + uniq(E + ',"saved"', true), 'n'],
    ['PDF success rate (saved / eResource requests)',
      pct(uniq(E + ',"saved"'), uniq(E + ',"check",' + G + ',"eresource"')),
      pct(uniq(E + ',"saved"', true), uniq(E + ',"check",' + G + ',"eresource"', true)), 'p'],
    ['Fetch attempts', '=' + cnt(E + ',"fetch"'), '=' + cnt(E + ',"fetch"', true), 'n'],
    ['Attempts that got a PDF', pct(cnt(E + ',"fetch",' + I + ',"fetched"'), cnt(E + ',"fetch"')), pct(cnt(E + ',"fetch",' + I + ',"fetched"', true), cnt(E + ',"fetch"', true)), 'p'],
    ['   Automatic fetches that got a PDF', pct(cnt(E + ',"fetch",' + L + ',"auto",' + I + ',"fetched"'), cnt(E + ',"fetch",' + L + ',"auto"')),
      pct(cnt(E + ',"fetch",' + L + ',"auto",' + I + ',"fetched"', true), cnt(E + ',"fetch",' + L + ',"auto"', true)), 'p'],
    ['Needed the browser (site bot check)', '=' + cnt(E + ',"fetch",' + I + ',"needs browser"'), '=' + cnt(E + ',"fetch",' + I + ',"needs browser"', true), 'n'],
    ['   Browser captures that worked', pct(cnt(E + ',"browser",' + I + ',"captured"'), cnt(E + ',"browser"')), pct(cnt(E + ',"browser",' + I + ',"captured"', true), cnt(E + ',"browser"', true)), 'p'],
    ['Average seconds per fetch', '=IFERROR(AVERAGEIFS(' + N + ',' + E + ',"fetch"),"")', '=IFERROR(AVERAGEIFS(' + N + ',' + E + ',"fetch"' + recent + '),"")', 's'],
    [''],
    ['REVIEW AND VERIFICATION'],
    ['PDFs reviewed', '=' + cnt(E + ',"review"'), '=' + cnt(E + ',"review"', true), 'n'],
    ['Saved after review', pct(cnt(E + ',"review",' + I + ',"saved"'), cnt(E + ',"review"')), pct(cnt(E + ',"review",' + I + ',"saved"', true), cnt(E + ',"review"', true)), 'p'],
    ['Wrong PDFs caught (Try again)', '=' + cnt(E + ',"review",' + I + ',"try again"'), '=' + cnt(E + ',"review",' + I + ',"try again"', true), 'n'],
    ['First-page check: Looks right', pct(cnt(E + ',"review",' + M + ',"ok"'), cnt(E + ',"review"')), pct(cnt(E + ',"review",' + M + ',"ok"', true), cnt(E + ',"review"', true)), 'p'],
    ['First-page check: Partly matches', pct(cnt(E + ',"review",' + M + ',"mid"'), cnt(E + ',"review"')), pct(cnt(E + ',"review",' + M + ',"mid"', true), cnt(E + ',"review"', true)), 'p'],
    ['First-page check: Check carefully', pct(cnt(E + ',"review",' + M + ',"bad"'), cnt(E + ',"review"')), pct(cnt(E + ',"review",' + M + ',"bad"', true), cnt(E + ',"review"', true)), 'p'],
    ['First-page check: not checked (scan, no text)', pct('(' + cnt(E + ',"review",' + M + ',"none"') + '+' + cnt(E + ',"review",' + M + ',"not read"') + ')', cnt(E + ',"review"')),
      pct('(' + cnt(E + ',"review",' + M + ',"none"', true) + '+' + cnt(E + ',"review",' + M + ',"not read"', true) + ')', cnt(E + ',"review"', true)), 'p'],
    ['When the check said "Looks right", staff saved it', pct(cnt(E + ',"review",' + M + ',"ok",' + I + ',"saved"'), cnt(E + ',"review",' + M + ',"ok"')),
      pct(cnt(E + ',"review",' + M + ',"ok",' + I + ',"saved"', true), cnt(E + ',"review",' + M + ',"ok"', true)), 'p'],
    ['When the check said "Check carefully", staff tried again', pct(cnt(E + ',"review",' + M + ',"bad",' + I + ',"try again"'), cnt(E + ',"review",' + M + ',"bad"')),
      pct(cnt(E + ',"review",' + M + ',"bad",' + I + ',"try again"', true), cnt(E + ',"review",' + M + ',"bad"', true)), 'p']
  ];

  d.getRange('A1').setValue('ILL Strategy Agent: how well it works').setFontSize(14).setFontWeight('bold');
  d.getRange('A2').setValue('Updates by itself as the addon sends results. Counts of requests use unique TNs.').setFontColor('#666666');
  d.getRange('A4:C4').setValues([['Measure', 'All time', 'Last 30 days']]).setFontWeight('bold');
  let r = 5;
  rows.forEach(row => {
    if (row.length === 1) {
      d.getRange(r, 1).setValue(row[0]).setFontWeight(row[0] ? 'bold' : 'normal');
    } else {
      d.getRange(r, 1).setValue(row[0]);
      d.getRange(r, 2).setFormula(row[1]);
      d.getRange(r, 3).setFormula(row[2]);
      const fmt = row[3] === 'p' ? '0%' : row[3] === 's' ? '0.0" s"' : '0';
      d.getRange(r, 2, 1, 2).setNumberFormat(fmt);
    }
    r++;
  });

  // Breakdowns (to the right)
  const Q = 'Log!$A$2:$O';
  d.getRange('E4').setValue('PDFs saved, by route').setFontWeight('bold');
  d.getRange('E5').setFormula('=IFERROR(QUERY(' + Q + ',"select J, count(F) where E = \'saved\' group by J order by count(F) desc label J \'Route\', count(F) \'PDFs saved\'",0),"No PDFs saved yet")');
  d.getRange('H4').setValue('Fetch results, by publisher site').setFontWeight('bold');
  d.getRange('H5').setFormula('=IFERROR(QUERY(' + Q + ',"select K, count(F) where E = \'fetch\' and K <> \'\' group by K pivot I label K \'Site\'",0),"No fetches yet")');
  d.getRange('E20').setValue('PDFs saved, by PC').setFontWeight('bold');
  d.getRange('E21').setFormula('=IFERROR(QUERY(' + Q + ',"select C, count(F) where E = \'saved\' group by C label C \'PC\', count(F) \'PDFs saved\'",0),"No PDFs saved yet")');
  d.getRange('H20').setValue('Checks and saves, by month').setFontWeight('bold');
  d.getRange('H21').setFormula('=IFERROR(QUERY(' + Q + ',"select year(A), month(A)+1, count(F) where E = \'check\' or E = \'saved\' group by year(A), month(A)+1 pivot E label year(A) \'Year\', month(A)+1 \'Month\'",0),"No data yet")');

  d.getRange('A40').setValue('Route names').setFontWeight('bold');
  d.getRange('A41:B49').setValues([
    ['alma1, alma2, ...', 'Bowdoin access link 1, 2, ... from Alma'],
    ['free', 'Free open-access copy'],
    ['ebsco', 'EBSCOhost API'],
    ['site', "Publisher rule from the DOI (Brill, De Gruyter Brill)"],
    ['doi', 'The DOI link was the PDF'],
    ['page', "PDF listed on the publisher's article page"],
    ['pagerule', "Publisher rule on the article page (e.g. Brill's Download PDF)"],
    ['browser', 'Caught in the PDF Preview tab (site bot check)'],
    ['How (Log tab)', 'auto = fetched when the tab opened; manual = Fetch PDF button; try again']
  ]);
  d.setColumnWidth(1, 330);
  d.setFrozenRows(4);
}
