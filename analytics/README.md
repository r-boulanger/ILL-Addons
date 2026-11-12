# ILL Strategy Agent analytics (Google Sheet)

Every PC running the addon sends one row per event to a Google Sheet, and the
**Dashboard** tab works out how well the addon is doing: how many citations it
verifies, the share of eResource requests that got a PDF, which routes found
them, how often staff caught a wrong PDF, and more. It updates by itself.

Rows hold the TN, the PC name, outcomes, routes and publisher sites only:
no titles, authors, DOIs or patron details.

## Set up (once, about 5 minutes)

1. Create a new Google Sheet (for example "ILL Strategy Agent analytics").
2. **Extensions → Apps Script**. Delete what's there, paste in `Code.gs`, and save.
3. In the function list at the top choose **setup** and click **Run**. Approve the
   permissions it asks for (it only touches this sheet). The **Execution log**
   at the bottom shows `AnalyticsKey for the addon settings: ...`: copy that key.
4. **Deploy → New deployment →** type **Web app**:
   - Execute as: **Me**
   - Who has access: **Anyone** (the addon can't sign in to Google; the key keeps other senders out)
   - Click **Deploy** and copy the **Web app URL** (`https://script.google.com/macros/s/.../exec`).
5. On each ILLiad PC, in **Manage Addons → ILL Strategy Agent**, set
   - **AnalyticsUrl** = the Web app URL
   - **AnalyticsKey** = the key from step 3
   and restart ILLiad.

Open a request: a row appears in the **Log** tab within a few seconds.

## Events

| Event   | When                                               | Outcome values |
|---------|----------------------------------------------------|----------------|
| check   | a citation check finishes                          | verified / unverified (Confidence column: High, Medium, Low, None) |
| fetch   | Fetch PDF finishes (auto, manual or try again)     | fetched / failed / needs browser |
| browser | a PDF Preview tab capture finishes                 | captured / failed |
| review  | staff click Save or Try again on a held PDF        | saved / try again (First-page check column: ok, mid, bad, none) |
| saved   | a PDF is saved as TN.pdf                           | |

## Notes

- Running **setup** again rebuilds the Dashboard and keeps the data and key.
- **newKey** makes a new key (then update AnalyticsKey on every PC).
- If you change `Code.gs` later, use **Deploy → Manage deployments → Edit →
  New version** so the same Web app URL keeps working.
- If a PC is offline, its rows wait on that PC and are sent with the next one.
