import sqlite3, os, json
p = os.path.join(os.environ['TEMP'], 'loop-t4-evidence', 'run1', 'data', 'loop.db')
c = sqlite3.connect(p); cur = c.cursor()
cols = [r[1] for r in cur.execute('pragma table_info(uploads)')]
rows = [dict(zip(cols, r)) for r in cur.execute('select * from uploads order by rowid desc limit 5')]
for r in rows:
    for k in list(r):
        if isinstance(r[k], bytes): r[k] = f'<{len(r[k])} bytes>'
print(json.dumps(rows, ensure_ascii=True))
c.close()
