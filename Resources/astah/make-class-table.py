#!/usr/bin/env python3
"""Writes Sources/SchemaCore/Astah/AstaClasses.swift from .asta files saved by Astah Professional.

    python3 Resources/astah/make-class-table.py sample1.asta [sample2.asta …]

An .asta file is a ZIP with one entry, EntityStore: a stream of Java objects. The stream describes every class
in it (name, serialVersionUID, fields); this script collects those descriptions, and for every field what it
holds in the samples: always the same value, an empty list, nothing, or something that differs per object (marked
"!", which the exporter then sets itself).

The samples must have at least one of everything the exporter writes: entities of each kind, attributes with a
length, a default and a domain, an index, every kind of relationship and a diagram with them on it. A class or a
field that is missing from the samples is missing from the table. Run it again after a new version of Astah
changes its model version, and run check.sh afterwards.
"""
import json, os, re, struct, sys, zipfile
from collections import Counter, OrderedDict

TC_NULL, TC_REFERENCE, TC_CLASSDESC, TC_OBJECT, TC_STRING, TC_ARRAY, TC_CLASS, TC_BLOCKDATA, TC_ENDBLOCKDATA, TC_RESET, TC_BLOCKDATALONG, TC_EXCEPTION, TC_LONGSTRING, TC_PROXYCLASSDESC, TC_ENUM = range(0x70, 0x7F)
BASE = 0x7E0000

class ClassDesc:
    def __init__(s): s.name=None; s.uid=0; s.flags=0; s.fields=[]; s.annotation=[]; s.super=None; s.handle=None
    def chain(s):
        c=[]; d=s
        while d is not None: c.append(d); d=d.super
        return list(reversed(c))
    def __repr__(s): return f"<class {s.name}>"
class Obj:
    def __init__(s, desc): s.desc=desc; s.data={}; s.annotations={}; s.handle=None
    def get(s, name):
        for cn, vals in s.data.items():
            if name in vals: return vals[name]
        raise KeyError(name)
    def __repr__(s): return f"<{s.desc.name.split('.')[-1]}#{s.handle-BASE}>"
class Arr:
    def __init__(s, desc): s.desc=desc; s.items=[]; s.handle=None
    def __repr__(s): return f"<arr {s.desc.name} n={len(s.items)}#{s.handle-BASE}>"
class JStr(str): pass
class Enum:
    def __init__(s, desc, name): s.desc=desc; s.name=name
class ClassRef:
    def __init__(s, desc): s.desc=desc
class Block(bytes): pass

class Reader:
    def __init__(s, data, skip=0):
        s.b=data; s.p=0; s.handles=[]
        assert s.u2()==0xACED and s.u2()==5
        s.extra = s.b[s.p:s.p+skip]; s.p+=skip
    def u1(s): v=s.b[s.p]; s.p+=1; return v
    def u2(s): v=struct.unpack_from('>H',s.b,s.p)[0]; s.p+=2; return v
    def i4(s): v=struct.unpack_from('>i',s.b,s.p)[0]; s.p+=4; return v
    def i8(s): v=struct.unpack_from('>q',s.b,s.p)[0]; s.p+=8; return v
    def utf(s): n=s.u2(); v=s.b[s.p:s.p+n]; s.p+=n; return v.decode('utf-8','surrogatepass')
    def new_handle(s, o): s.handles.append(o); return BASE+len(s.handles)-1
    def contents(s):
        out=[]
        while s.p < len(s.b): out.append(s.content())
        return out
    def content(s):
        t=s.b[s.p]
        if t==TC_BLOCKDATA: s.p+=1; n=s.u1(); v=Block(s.b[s.p:s.p+n]); s.p+=n; return v
        if t==TC_BLOCKDATALONG: s.p+=1; n=s.i4(); v=Block(s.b[s.p:s.p+n]); s.p+=n; return v
        if t==TC_RESET: s.p+=1; return 'RESET'
        return s.obj()
    def obj(s):
        t=s.u1()
        if t==TC_NULL: return None
        if t==TC_REFERENCE: return s.handles[s.i4()-BASE]
        if t==TC_CLASSDESC: s.p-=1; return s.classdesc()
        if t==TC_PROXYCLASSDESC: raise Exception('proxy')
        if t==TC_STRING:
            v=JStr(s.utf()); s.new_handle(v); return v
        if t==TC_LONGSTRING:
            n=s.i8(); v=JStr(s.b[s.p:s.p+n].decode('utf-8','surrogatepass')); s.p+=n; s.new_handle(v); return v
        if t==TC_CLASS:
            d=s.classdesc(); v=ClassRef(d); s.new_handle(v); return v
        if t==TC_ENUM:
            d=s.classdesc(); e=Enum(d,None); s.new_handle(e); e.name=s.obj(); return e
        if t==TC_ARRAY:
            d=s.classdesc(); a=Arr(d); a.handle=s.new_handle(a); n=s.i4(); et=d.name[1]
            for _ in range(n): a.items.append(s.value(et))
            return a
        if t==TC_OBJECT:
            d=s.classdesc(); o=Obj(d); o.handle=s.new_handle(o)
            for c in d.chain():
                if c.flags & 0x04: # externalizable
                    assert c.flags & 0x08, 'old externalizable'
                    o.annotations[c.name]=s.annotation()
                    continue
                vals={}
                for (tc,name,cls) in c.fields: vals[name]=s.value(tc)
                o.data[c.name]=vals
                if c.flags & 0x01: o.annotations[c.name]=s.annotation()
            return o
        raise Exception(f'bad tc {t:#x} at {s.p-1}')
    def annotation(s):
        out=[]
        while True:
            if s.b[s.p]==TC_ENDBLOCKDATA: s.p+=1; return out
            out.append(s.content())
    def classdesc(s):
        t=s.u1()
        if t==TC_NULL: return None
        if t==TC_REFERENCE: return s.handles[s.i4()-BASE]
        assert t==TC_CLASSDESC, f'classdesc tc {t:#x} at {s.p-1}'
        d=ClassDesc(); d.name=s.utf(); d.uid=s.i8(); d.handle=s.new_handle(d); d.flags=s.u1()
        for _ in range(s.u2()):
            tc=chr(s.u1()); name=s.utf(); cls=None
            if tc in 'L[': cls=s.obj()
            d.fields.append((tc,name,cls))
        d.annotation=s.annotation(); d.super=s.classdesc(); return d
    def value(s, tc):
        if tc=='B': return struct.unpack('>b',bytes([s.u1()]))[0]
        if tc=='C': return chr(s.u2())
        if tc=='D': v=struct.unpack_from('>d',s.b,s.p)[0]; s.p+=8; return v
        if tc=='F': v=struct.unpack_from('>f',s.b,s.p)[0]; s.p+=4; return v
        if tc=='I': return s.i4()
        if tc=='J': return s.i8()
        if tc=='S': v=struct.unpack_from('>h',s.b,s.p)[0]; s.p+=2; return v
        if tc=='Z': return s.u1()!=0
        return s.obj()

def load(path):
    z=zipfile.ZipFile(path)
    return {n: z.read(n) for n in z.namelist()}


def short(o): return o.desc.name.split('.')[-1]
def items(o): return [x for x in o.annotations.get(o.desc.name, []) if not isinstance(x, Block)]

def kind(tc, v):
    """What a field holds, in the words of the table."""
    if tc in 'BCDFIJSZ': return 'p:' + json.dumps(v)
    if v is None: return 'null'
    if isinstance(v, JStr): return 's:' + json.dumps(str(v))
    if isinstance(v, Arr): return 'array'
    if isinstance(v, Obj):
        n = short(v)
        if n == 'ArrayList': return 'list'
        if n == 'HashMap': return 'map'
        if n == 'HashSet': return 'set'
        if n in ('UVisibilityKind', 'UScopeKind', 'UChangeableKind', 'UAggregationKind'): return f'kind:{n}:{v.get("label")}'
        if n in ('UName', 'UUninterpreted'): return 'text:' + n
        if n in ('Vec2d', 'Pnt2d'): return 'pt:' + n
        if n == 'Long': return 'long'
        return 'obj'
    return '?'

def main(samples):
    classes = OrderedDict()
    seen = {}
    for path in samples:
        reader = Reader(load(path)['EntityStore'], 4)   # Astah puts four bytes of its own after the stream's header
        reader.contents()
        for h in reader.handles:
            if isinstance(h, ClassDesc): classes.setdefault(h.name, h)
            if isinstance(h, Obj):
                for c in h.desc.chain():
                    for tc, name, _ in c.fields:
                        if c.name in h.data: seen.setdefault((c.name, name), Counter())[kind(tc, h.data[c.name][name])] += 1
    lines = []
    for name, d in classes.items():
        lines.append(f'{name} {d.uid} {d.flags} {d.super.name if d.super else "-"}')
        for tc, field, signature in d.fields:
            found = seen.get((name, field), Counter())
            kinds = set(found)
            if len(kinds) == 1 and next(iter(kinds)) not in ('obj', 'array', 'set'):
                preset = next(iter(kinds))
            else:
                # It differs: the exporter sets it. A number keeps its most common value to fall back on.
                common = found.most_common(1)[0][0] if found else ''
                preset = '!' + (common if common.startswith('p:') else '')
            if field == 'text' and signature == 'Ljava/lang/String;': preset = '!'
            lines.append(f' {tc} {field} {signature if signature else "-"} {preset}'.rstrip())
    body = '\n'.join(lines).replace('JP.co.esm.caddies.', '~').replace('LJP/co/esm/caddies/', 'L~/')
    assert '"""' not in body
    target = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'Sources', 'SchemaCore', 'Astah', 'AstaClasses.swift')
    head = open(target).read().split('enum AstaClasses {')[0]
    open(target, 'w').write(head + 'enum AstaClasses {\n    static let table = #"""\n' + body + '\n"""#\n}\n')
    print(f'{len(classes)} classes, {len(lines) - len(classes)} fields -> {os.path.normpath(target)}')

if __name__ == '__main__':
    if len(sys.argv) < 2: sys.exit(__doc__)
    main(sys.argv[1:])
