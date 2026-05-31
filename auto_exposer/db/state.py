import sqlite3
import json
from typing import Dict

class StateManager:
    def __init__(self, db_path="state.sqlite"):
        self.conn = sqlite3.connect(db_path)
        self.cursor = self.conn.cursor()
        self._init_db()

    def _init_db(self):
        self.cursor.execute('''
            CREATE TABLE IF NOT EXISTS hosts (
                domain TEXT PRIMARY KEY,
                ip TEXT,
                port INTEGER,
                npm_id INTEGER,
                data TEXT
            )
        ''')
        self.conn.commit()

    def get_all(self):
        self.cursor.execute('SELECT domain, ip, port, npm_id, data FROM hosts')
        return self.cursor.fetchall()

    def save(self, domain, ip, port, npm_id, data):
        self.cursor.execute('''
            INSERT OR REPLACE INTO hosts (domain, ip, port, npm_id, data)
            VALUES (?, ?, ?, ?, ?)
        ''', (domain, ip, port, npm_id, json.dumps(data)))
        self.conn.commit()
