# Parte 2 del generador: Anexos V, VI y IX. Devuelve filas para codigo_sisesat.
import re, collections, xlrd

def _ws(s): return re.sub(r'\s+', ' ', str(s).replace('\xa0', ' ')).strip()
def _v(c):
    x = c.value
    if isinstance(x, float): return str(int(x)) if x == int(x) else str(x)
    return _ws(x)

def anexo_v(path):
    sh = xlrd.open_workbook(path).sheet_by_index(0)
    glosas = collections.OrderedDict()
    for r in range(3, sh.nrows):
        c, d = _v(sh.cell(r, 0)), _v(sh.cell(r, 1))
        if not re.fullmatch(r'[ST]\d{2}[0-9X]{0,2}', c): continue
        assert d, c
        glosas.setdefault(c, [])
        if d not in glosas[c]: glosas[c].append(d)
    filas = []
    for c, ds in glosas.items():
        padre = (c[:4] if len(c) == 5 and c[:4] in glosas else c[:3]) if len(c) > 3 else None
        filas.append(dict(clas='lesion_cie10', codigo=c, padre=padre, grupo=None,
                          desc=ds[0], terminos=ds[1:], alterno=None, sel=True, obs=None))
    return filas

def anexo_vi(path):
    sh = xlrd.open_workbook(path).sheet_by_index(0)
    filas = []; region = None; problemas = []
    for r in range(6, sh.nrows):
        c, d, g = (_v(sh.cell(r, i)) for i in range(3))
        if not c or c.startswith('['): continue
        # La grafía numérica (121) es la forma sin ambigüedad; de ella sale el código con puntos.
        assert re.fullmatch(r'\d{3,4}', g), (c, g)
        partes = [g[:-2], g[-2], g[-1]]
        esperado = '.'.join(p for p in partes if p != '0') if partes[1] != '0' or partes[2] != '0' else partes[0]
        if partes[1] == '0' and partes[2] != '0': esperado = f"{partes[0]}.0.{partes[2]}"
        if esperado != c: problemas.append((c, g))
        if '.' not in c: region = f"{c}. {d}"
        filas.append(dict(clas='ubicacion_lesion', codigo=c, padre=c.rsplit('.', 1)[0] if '.' in c else None,
                          grupo=region, desc=d, terminos=[], alterno=g, sel=True, obs=None))
    assert not problemas, problemas
    return filas

def anexo_ix(path):
    sh = xlrd.open_workbook(path).sheet_by_index(0)
    crudas = []
    for r in range(7, sh.nrows):
        x = [_v(sh.cell(r, i)) for i in range(10)]
        if x[8]: crudas.append(x)
    originales = {x[8] for x in crudas}
    filas = []; normalizados = []; ambiguos = []
    for x in crudas:
        a, b, c, d, e, f = x[:6]; orig = x[8]; obs = None
        rearmado = a + b + c.zfill(2) + d.zfill(2) + e.zfill(2) + f.zfill(2) if len(b) == 1 else None
        codigo = orig
        if not re.fullmatch(r'\d{10}', orig):
            if rearmado and re.fullmatch(r'\d{10}', rearmado) and rearmado not in originales:
                codigo = rearmado; normalizados.append((orig, rearmado))
                obs = f"Código original del anexo: {orig} (columna sin cero inicial); se normalizó a {rearmado}."
            else:
                ambiguos.append(orig)
                obs = f"El anexo trae el código {orig}, que no tiene 10 dígitos y no admite una corrección evidente; se conserva tal cual."
        elif rearmado and rearmado != orig:
            raise SystemExit(f"código distinto a sus columnas: {orig} vs {rearmado}")
        filas.append(dict(clas='agente_enfermedad', codigo=codigo, padre=None, grupo=None, desc=x[6],
                          terminos=[], alterno=None, sel=(x[9] != '*'), obs=obs))
    # Jerarquía: el padre es la agrupación más profunda cuyo prefijo significativo contiene al código.
    def segs(code):
        if len(code) != 10: return None
        s = [code[0], code[1], code[2:4], code[4:6], code[6:8], code[8:10]]
        while s and s[-1] in ('0', '00'): s.pop()
        return s
    grupos = [(segs(g['codigo']), g) for g in filas if not g['sel'] and segs(g['codigo'])]
    tope = {}
    for g in filas:
        s = segs(g['codigo'])
        if s is None: continue
        cands = [(len(gs), gg) for gs, gg in grupos if len(gs) < len(s) and s[:len(gs)] == gs]
        if cands:
            g['padre'] = max(cands, key=lambda t: t[0])[1]['codigo']
        nivel1 = [gg for gs, gg in grupos if len(gs) == 1 and s[:1] == gs]
        if nivel1: g['grupo'] = nivel1[0]['desc']
    assert len({g['codigo'] for g in filas}) == len(filas)
    return filas, normalizados, ambiguos
