# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
# Download the source MP3 of the selected archive.org items; record url, size, sha256, licence, metadata.
import json, os, sys, hashlib, urllib.request, urllib.parse
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IDS = ["sesionextraordinariaconcejodeliberante18diciembre2019", "concejodeliberante211119", "sesiondelconcejodeliberante241019",
       "SesinDelConcejoDeliberante120619AsumeTorresConferenciaDePrensaYSolicitudCiudad", "AudioConcejoDeliberante251018",
       "concejodeliberante290819", "concejo-deliberante-capilla-del-monte-sesion-25-06-20", "concejo-deliberante-03-09-20", "comisionconcejodeliberantetemavillacielo", "debate-concejo-deliberante-emergencia-economica"]
os.makedirs(f"{H}/audio/src", exist_ok=True)
out = {}
for i in IDS:
    md = json.load(urllib.request.urlopen("https://archive.org/metadata/" + i))
    m = md["metadata"]
    f = max((f for f in md["files"] if f["name"].lower().endswith(".mp3") and f.get("length")), key=lambda f: float(f["length"]))
    url = f"https://archive.org/download/{i}/" + urllib.parse.quote(f["name"])
    dest = f"{H}/audio/src/{i[:40]}.mp3"
    if not os.path.exists(dest):
        import subprocess
        for attempt in range(40):
            r = subprocess.run(["curl","-sS","-L","-C","-","--connect-timeout","20","--speed-limit","300000","--speed-time","15","-o",dest+".part",url])
            if r.returncode == 0: os.replace(dest+".part", dest); break
    h = hashlib.sha256(open(dest, "rb").read()).hexdigest()
    out[i] = dict(url=url, page=f"https://archive.org/details/{i}", file=os.path.basename(dest), bytes=os.path.getsize(dest), sha256=h,
                  archive_sha1=f.get("sha1"), seconds=float(f["length"]), title=m.get("title"), date=m.get("date") or m.get("publicdate"),
                  creator=m.get("creator"), uploader=m.get("uploader"), licenseurl=m.get("licenseurl"), language=m.get("language"))
    print(i, out[i]["bytes"], out[i]["licenseurl"], flush=True)
json.dump(out, open(f"{H}/data/es_sources.json", "w"), indent=1, ensure_ascii=False)
