"""Aplica Tools/translations-en.json ao App/Localizable.xcstrings (rodar na raiz).
Uso: python3 Tools/apply-translations.py  → lista as chaves ainda sem inglês."""
import json
catalog_path, en_path = "App/Localizable.xcstrings", "Tools/translations-en.json"
catalog = json.load(open(catalog_path))
en = json.load(open(en_path))
# Textos que saíram do código (marcados "stale" pelo sync) são removidos.
stale = [k for k, e in catalog["strings"].items() if e.get("extractionState") == "stale"]
for key in stale:
    del catalog["strings"][key]
missing = []
for key, entry in catalog["strings"].items():
    # Português explícito: sem ele, o build só gera en.lproj e um Mac em português abriria em inglês.
    entry.setdefault("localizations", {})["pt-BR"] = {"stringUnit": {"state": "translated", "value": key}}
    if key in en:
        entry["localizations"]["en"] = {"stringUnit": {"state": "translated", "value": en[key]}}
    else:
        missing.append(key)
json.dump(catalog, open(catalog_path, "w"), ensure_ascii=False, indent=2, sort_keys=True)
open(catalog_path, "a").write("\n")
print(f"traduzidas: {len(catalog['strings']) - len(missing)} · sem inglês: {len(missing)} · removidas: {len(stale)}")
for key in missing:
    print("  ", repr(key))
