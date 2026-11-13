#!/usr/bin/env python3
"""
ebsco_eit.py - call the EBSCOhost API (EIT) from the Mac Terminal.

Makes the same calls as the ILLiad addon's EBSCO route (StrategyAgent.lua):
  Info    lists the databases your profile can search
  Search  finds a record by DOI, or by title + author
  then, if the record lists a PDF link, it can download the PDF.

The profile comes from DEFAULT_PROFILE below or EBSCO_PROFILE, or is asked for.
The password is read from EBSCO_PASSWORD, or asked for when the script starts
(it isn't shown as you type). It is never printed or stored.

Examples
  python3 ebsco_eit.py info
  python3 ebsco_eit.py search --doi 10.1080/02560046.2024.2391344
  python3 ebsco_eit.py search --title "Unlocking the Perfect Beat" --author Gyselinck
  python3 ebsco_eit.py search --doi 10.1080/02560046.2024.2391344 --download 123456.pdf
  python3 ebsco_eit.py search --doi 10.1080/02560046.2024.2391344 --raw    (prints EBSCO's XML)

To skip the prompts, set these first (in the same Terminal window):
  export EBSCO_PROFILE="customerID.groupID.profileID"
  read -s EBSCO_PASSWORD && export EBSCO_PASSWORD
"""
import argparse
import getpass
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

BASE = "https://eit.ebscohost.com/Services/SearchService.asmx"
DEFAULT_PROFILE = ""   # put your EIT profile here (customerID.groupID.profileID), or set EBSCO_PROFILE
USER_AGENT = "Mozilla/5.0 (Macintosh) ILLiad-CitationCheck/2.2"
STOP = set("a an the of and in on for to with from by at as or not".split())


# ---------- credentials ----------
def credentials():
    prof = os.environ.get("EBSCO_PROFILE", "").strip() or DEFAULT_PROFILE
    pwd = os.environ.get("EBSCO_PASSWORD", "")
    if not prof:
        prof = input("EBSCO profile (customerID.groupID.profileID): ").strip()
    if not pwd:
        pwd = getpass.getpass("EBSCO password: ")
    if not prof or not pwd:
        sys.exit("A profile and a password are both needed.")
    return prof, pwd


# ---------- HTTP ----------
def eit_get(method, params, prof, pwd):
    """GET one EIT address; returns the response text. Errors never show the password."""
    query = [("prof", prof), ("pwd", pwd)] + params
    url = BASE + "/" + method + "?" + urllib.parse.urlencode(query)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/xml, text/xml"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        detail = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", body)).strip()
        sys.exit(f"EBSCO answered {e.code} {e.reason}" + (f": {detail[:300]}" if detail else ""))
    except urllib.error.URLError as e:
        sys.exit(f"Couldn't reach EBSCO: {e.reason}")


# ---------- XML (namespace-agnostic) ----------
def local(tag):
    return tag.rsplit("}", 1)[-1]


def parse(text):
    try:
        return ET.fromstring(text)
    except ET.ParseError:
        sys.exit("EBSCO sent back something that isn't XML: " + re.sub(r"<[^>]+>", " ", text)[:300])


def find_all(node, name):
    return [el for el in node.iter() if local(el.tag) == name]


def find_text(node, name, **attrs):
    for el in node.iter():
        if local(el.tag) == name and all(el.get(k) == v for k, v in attrs.items()):
            text = "".join(el.itertext()).strip()
            if text:
                return text
    return None


# ---------- EIT calls ----------
def databases(prof, pwd):
    text = eit_get("Info", [], prof, pwd)
    root = parse(text)
    names = []
    for db in find_all(root, "db"):
        short = db.get("shortName")
        if short and short not in names:
            names.append(short)
    if not names:
        msg = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", text)).strip()
        sys.exit("EBSCO didn't list any databases for this profile. It said: " + msg[:300])
    return names


def records(text):
    out = []
    for rec in find_all(parse(text), "rec"):
        header = next((el for el in rec.iter() if local(el.tag) == "header"), None)
        pdf = None
        for el in rec.iter():
            if local(el.tag).lower() == "pdflink":
                value = "".join(el.itertext()).strip()
                if value.startswith("http"):
                    pdf = value
                    break
        fields = []
        for el in rec.iter():
            n = local(el.tag)
            if el is not rec and n not in fields:
                fields.append(n)
        out.append({
            "db": header.get("shortDbName") if header is not None else None,
            "an": header.get("uiTerm") if header is not None else None,
            "title": find_text(rec, "atl") or find_text(rec, "btl") or "",
            "doi": find_text(rec, "ui", type="doi"),
            "pdf": pdf,
            "plink": find_text(rec, "plink"),
            "fields": fields,
        })
    return out


def words(s):
    return [w for w in re.findall(r"\w+", (s or "").lower()) if w not in STOP and len(w) > 1]


def title_overlap(want, got):
    w, g = words(want), set(words(got))
    return sum(1 for x in w if x in g) / len(w) if w else 0.0


def matches(r, doi, title):
    doi_match = bool(doi) and r["doi"] is not None and r["doi"].lower() == doi.lower()
    title_match = bool(title) and title_overlap(title, r["title"]) >= 0.8
    doi_conflict = bool(doi) and r["doi"] is not None and not doi_match
    return doi_match or (title_match and not doi_conflict)


def title_query(title, author):
    w = words(title)[:8]
    if not w:
        return None
    q = "TI (" + " AND ".join(w) + ")"
    au = words(author)
    if au:
        q += " AND AU " + au[0]
    return q


# ---------- commands ----------
def cmd_info(args):
    prof, pwd = credentials()
    dbs = databases(prof, pwd)
    print(f"Sign-in OK. {len(dbs)} database(s): " + ", ".join(dbs))


def cmd_search(args):
    if not args.doi and not args.title:
        sys.exit("Give --doi, or --title (and optionally --author).")
    prof, pwd = credentials()
    dbs = args.db or databases(prof, pwd)
    print(f"Searching {len(dbs)} database(s)...")
    queries = []
    if args.doi:
        queries.append(f'"{args.doi}"')
    tq = title_query(args.title, args.author)
    if tq:
        queries.append(tq)

    best = None
    for q in queries:
        params = [("query", q)] + [("db", d) for d in dbs] + [
            ("startrec", "1"), ("numrec", str(args.n)), ("format", "detailed"),
            ("sort", "relevance"), ("authType", "profile")]
        text = eit_get("Search", params, prof, pwd)
        if args.raw:
            print(f"\n----- raw XML for query {q} -----\n{text}\n")
        recs = records(text)
        print(f"\nQuery {q}: {len(recs)} record(s)")
        for i, r in enumerate(recs, 1):
            ok = matches(r, args.doi or "", args.title or "")
            print(f"  {i}. [{r['db']} {r['an']}] {r['title'][:90]}")
            print(f"     DOI: {r['doi'] or '-'}   match: {'YES' if ok else 'no'}   PDF link: {'yes' if r['pdf'] else 'no'}")
            if ok and r["pdf"] is None:
                print(f"     record fields: {', '.join(r['fields'])}")
            if ok and best is None:
                best = r
        if best is not None and best["pdf"]:
            break

    if best is None:
        print("\nNo matching record.")
        return
    if not best["pdf"]:
        print(f"\nFound the record ({best['db']} {best['an']}), but EBSCO lists no PDF link for it.")
        if best["plink"]:
            print("Record page: " + best["plink"])
        return
    print(f"\nPDF link for {best['db']} {best['an']}:\n{best['pdf']}")
    if args.download:
        download(best["pdf"], args.download)


def download(url, path):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/pdf,*/*"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = resp.read()
    except urllib.error.URLError as e:
        sys.exit(f"Download failed: {getattr(e, 'reason', e)}")
    if b"%PDF" not in data[:1024]:
        sys.exit("The link returned a web page, not a PDF (often a login page: try from a campus IP).")
    with open(path, "wb") as f:
        f.write(data)
    print(f"Saved {len(data) / 1048576:.1f} MB to {os.path.abspath(path)}")


def main():
    ap = argparse.ArgumentParser(description="Call the EBSCOhost API (EIT) from the Terminal.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("info", help="check sign-in and list your databases").set_defaults(func=cmd_info)
    s = sub.add_parser("search", help="find a record by DOI or title + author")
    s.add_argument("--doi")
    s.add_argument("--title")
    s.add_argument("--author", help="author's surname")
    s.add_argument("--db", action="append", help="search only this database (repeatable, e.g. --db a9h)")
    s.add_argument("-n", type=int, default=10, help="records per query (default 10)")
    s.add_argument("--download", metavar="FILE.pdf", help="save the PDF if a link is found")
    s.add_argument("--raw", action="store_true", help="also print EBSCO's raw XML")
    s.set_defaults(func=cmd_search)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
