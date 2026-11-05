# Genera db/seed_sisesat.sql desde los Anexos II, III y IV del Manual Técnico
# de Codificación SISESAT (SUSESO).
#
# Uso: python3 db/scripts/generar_seed_sisesat.py ANEXO_II.xlsx ANEXO_III.xlsx ANEXO_IV.xls db/seed_sisesat.sql
# Requiere: pip install openpyxl xlrd

import sys, re, json, collections, openpyxl, xlrd
a2, a3, a4, out = sys.argv[1:5]
ws_ = lambda s: re.sub(r'\s+', ' ', s.replace('\xa0', ' ')).strip()
q = lambda s: "NULL" if s is None else "'" + s.replace("'", "''") + "'"

# ---- Anexo II: forma del accidente (SUSESO 2018)
forma = []; agr = sub = oit = None
ws = openpyxl.load_workbook(a2, data_only=True)['Código Forma']
for row in list(ws.iter_rows(values_only=True))[4:]:
    a, b, c, d, e = [ws_(str(x)) if x is not None else '' for x in row]
    if not d: continue
    if a: agr = a
    if b: sub = b
    if c: oit = c
    assert d.startswith(oit + '.'), d
    forma.append((d, oit, f"{agr} / {sub}", e))
formas_oit = {f[1] for f in forma}
assert len(forma) == 60 and len({f[0] for f in forma}) == 60

# ---- Anexo III: agente material (2018)
agente = []; grupo = None
ws = openpyxl.load_workbook(a3, data_only=True)['Clasificacion agente 2018']
for row in list(ws.iter_rows(values_only=True))[2:]:
    g, sg, c, d = [ws_(str(x)) if x is not None else '' for x in row]
    if g: grupo = f"{g}. {d.rstrip(':').strip()}"
    if c: agente.append([c, None, grupo, d.rstrip(':').strip()])
codes_ag = {x[0] for x in agente}
for x in agente:
    c = x[0]
    if '.' in c: x[1] = c.split('.')[0]
    elif not c.endswith('0') and c[:2] + '0' in codes_ag: x[1] = c[:2] + '0'
padres_ag = {x[1] for x in agente if x[1]}
assert len(agente) == 145 and len(codes_ag) == 145
valido_ag = codes_ag | padres_ag

# ---- Anexo IV: causa externa CIE-10 cap. XX y equivalencias
sh = xlrd.open_workbook(a4).sheet_by_index(0)
def v(cell):
    x = cell.value
    if isinstance(x, float): return str(int(x)) if x == int(x) else str(x)
    return ws_(str(x))
cie = collections.OrderedDict(); dup = collections.defaultdict(list); header = None
for r in range(1, sh.nrows):
    row = [v(c) for c in sh.row(r)]
    if not row[3]:
        header = f"{row[0]} {row[4]}".strip(); continue
    code = row[3]; assert row[2].replace('.', '') == code
    if code in cie:
        dup[code].append(row[4])
        assert (row[5], row[6]) == (cie[code]['f'], cie[code]['a']), code
        continue
    cie[code] = dict(desc=row[4], cat=row[0], grupo=header, f=row[5], a=row[6])

def opciones(texto):
    return [p.strip() for p in re.split(r'\s+[óÓ]\s+', texto) if p.strip()]
eq = []; anomalias = collections.Counter()
for code, d in cie.items():
    obs = []; formas = []; agentes = []
    for p in opciones(d['f']):
        if p.startswith('¿'):
            p = p.strip('¿?'); obs.append(f"El Anexo IV marca la forma {p} con duda (¿{p}?)."); anomalias['forma dudosa (¿34?)'] += 1
        if p in formas_oit: formas.append(p)
        elif p == '234':
            obs.append("La columna de forma trae 234, que es un código de agente, no de forma."); anomalias['forma 234 (es código de agente)'] += 1
        else:
            obs.append(f"La forma {p} no existe en el Anexo II (2018)."); anomalias[f'forma {p} inexistente en Anexo II'] += 1
    for p in opciones(d['a']):
        m = re.fullmatch(r'(\d{3})\s+[aA]\s+(\d{3})', p)
        if m:
            agentes += sorted(c for c in codes_ag if '.' not in c and m.group(1) <= c <= m.group(2))
        elif p in valido_ag: agentes.append(p)
        else:
            obs.append(f"El agente {p} no existe en el Anexo III (2018)."); anomalias[f'agente {p} inexistente en Anexo III'] += 1
    if code in dup:
        obs.append(f"El Anexo IV repite este código con {len(dup[code])+1} descripciones distintas; se usa la primera.")
        anomalias['código repetido con otra descripción'] += 1
    eq.append((code, formas, agentes, d['f'] or None, d['a'] or None, ' '.join(obs) or None))

arr = lambda xs: "'{" + ",".join(xs) + "}'"
L = []
L.append("""-- =============================================================================
-- Paritario — códigos SISESAT para la investigación de accidentes.
-- Ejecutar después de schema.sql.
--
-- Fuentes oficiales (SUSESO, Manual Técnico de Codificación SISESAT):
--   Anexo II   Clasificación de la forma del accidente OIT, códigos SUSESO
--              2018: %d códigos de detalle bajo %d códigos OIT.
--   Anexo III  Clasificación del agente material OIT, versión 2018:
--              %d códigos.
--   Anexo IV   Tabla de equivalencias entre la CIE-10 (cap. XX) y la forma
--              y el agente OIT: %d códigos de causa externa.
--
-- Las equivalencias guardan solo opciones que existen en los Anexos II y III.
-- Anomalías del Anexo IV, anotadas fila por fila en
-- equivalencia_cie10_oit.observacion (filas afectadas):
""" % (len(forma), len(formas_oit), len(agente), len(cie)))
for k, n in sorted(anomalias.items()):
    L.append(f"--   {k}: {n}\n")
L.append("""--
-- Pendientes: Anexo I (CIE-10 cap. XX completo con intencionalidad), V
-- (CIE-10 cap. XIX), VI (ubicación anatómica), IX (agentes de enfermedad) y
-- CIE-10 cap. I a XVIII.
-- =============================================================================

BEGIN;
SET search_path = paritario, public;

INSERT INTO codigo_sisesat (clasificacion, codigo, codigo_padre, grupo, descripcion) VALUES
""")
vals = [f"    ('forma_accidente', {q(c)}, {q(p)}, {q(g)}, {q(d)})" for c, p, g, d in forma]
vals += [f"    ('agente_material', {q(c)}, {q(p)}, {q(g)}, {q(d)})" for c, p, g, d in agente]
vals += [f"    ('causa_externa_cie10', {q(c)}, {q(d['cat'])}, {q(d['grupo'])}, {q(d['desc'])})" for c, d in cie.items()]
L.append(",\n".join(vals) + ";\n\nINSERT INTO equivalencia_cie10_oit (cie10_codigo, formas_oit, agentes_oit, texto_forma, texto_agente, observacion) VALUES\n")
L.append(",\n".join(f"    ({q(c)}, {arr(f)}, {arr(a)}, {q(tf)}, {q(ta)}, {q(o)})" for c, f, a, tf, ta, o in eq) + ";\n\nCOMMIT;\n")
open(out, 'w', encoding='utf-8').write(''.join(L))
print(json.dumps(dict(forma=len(forma), agente=len(agente), cie10=len(cie), equivalencias=len(eq),
    sin_forma=sum(1 for e in eq if not e[1]), sin_agente=sum(1 for e in eq if not e[2]),
    con_observacion=sum(1 for e in eq if e[5]), anomalias=anomalias), ensure_ascii=False, indent=1))
