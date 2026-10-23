import sqlite3

from db import SCHEMA
from retrieval import chunk_pages, index_material, remove_material_index, search, tokenize


def make_conn():
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    conn.execute(
        "INSERT INTO materials(id, name, kind, status, created_at) "
        "VALUES(1, '线性代数讲义.pdf', 'pdf', 'ready', '2026-01-01')"
    )
    conn.execute(
        "INSERT INTO materials(id, name, kind, status, created_at) "
        "VALUES(2, '英语阅读.pdf', 'pdf', 'ready', '2026-01-01')"
    )
    return conn


def test_tokenize_chinese_bigram():
    tokens = tokenize("特征值与特征向量")
    assert "特征" in tokens
    assert "征值" in tokens
    assert all(len(t) <= 8 for t in tokens)


def test_chunk_pages_keeps_page_numbers():
    pages = ["第一页内容。" * 200, "第二页内容。" * 200]
    chunks = chunk_pages(pages, size=300, overlap=50)
    assert chunks
    assert {page for page, _ in chunks} == {1, 2}
    assert all(len(text) <= 400 for _, text in chunks)


def test_index_and_search_hits_right_page():
    conn = make_conn()
    pages = ["矩阵的秩与线性方程组", "特征值与特征向量：A x = λ x，几何意义是方向不变"]
    index_material(conn, 1, pages)
    hits = search(conn, "特征值 几何意义")
    assert hits, "应该有命中"
    assert hits[0]["page"] == 2
    assert hits[0]["material_name"] == "线性代数讲义.pdf"


def test_search_across_all_materials():
    conn = make_conn()
    index_material(conn, 1, ["特征值是线性代数的核心概念"])
    index_material(conn, 2, ["feature extraction in machine learning"])
    hits = search(conn, "特征值")
    assert hits and hits[0]["material_id"] == 1
    english = search(conn, "feature extraction")
    assert english and english[0]["material_id"] == 2


def test_remove_material_cleans_index():
    conn = make_conn()
    index_material(conn, 1, ["特征值分解"])
    remove_material_index(conn, 1)
    assert search(conn, "特征值") == []
    assert conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0] == 0
