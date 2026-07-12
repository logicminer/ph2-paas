import Database from 'better-sqlite3';
import { mkdirSync } from 'fs';
import { dirname, join } from 'path';

const DB_PATH = join(process.env.DATA_DIR || '/app/data', 'panel.db');

// Ensure the directory exists
try {
  mkdirSync(dirname(DB_PATH), { recursive: true });
} catch (e) {
  // directory may already exist
}

let _db = null;

export function getDb() {
  if (_db) return _db;

  _db = new Database(DB_PATH);
  _db.pragma('journal_mode = WAL');

  // Create tables if they don't exist
  _db.exec(`
    CREATE TABLE IF NOT EXISTS sites (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      domain TEXT UNIQUE NOT NULL,
      type TEXT NOT NULL DEFAULT 'wordpress',
      status TEXT NOT NULL DEFAULT 'active',
      wp_admin_user TEXT,
      wp_admin_password TEXT,
      wp_admin_email TEXT,
      wp_title TEXT,
      db_name TEXT,
      db_user TEXT,
      db_password TEXT,
      docroot TEXT,
      zone TEXT,
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS spawn_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      site_domain TEXT,
      line TEXT,
      stream TEXT DEFAULT 'stdout',
      created_at TEXT DEFAULT (datetime('now'))
    );
  `);

  return _db;
}

export function insertSite(site) {
  const db = getDb();
  const stmt = db.prepare(`
    INSERT OR REPLACE INTO sites
      (domain, type, status, wp_admin_user, wp_admin_password, wp_admin_email,
       wp_title, db_name, db_user, db_password, docroot, zone, updated_at)
    VALUES
      (@domain, @type, @status, @wp_admin_user, @wp_admin_password, @wp_admin_email,
       @wp_title, @db_name, @db_user, @db_password, @docroot, @zone, datetime('now'))
  `);
  return stmt.run(site);
}

export function getSite(domain) {
  const db = getDb();
  return db.prepare('SELECT * FROM sites WHERE domain = ?').get(domain);
}

export function getAllSites() {
  const db = getDb();
  return db.prepare('SELECT * FROM sites ORDER BY created_at DESC').all();
}

export function updateSiteStatus(domain, status) {
  const db = getDb();
  return db.prepare('UPDATE sites SET status = ?, updated_at = datetime(\'now\') WHERE domain = ?').run(status, domain);
}

export function deleteSite(domain) {
  const db = getDb();
  return db.prepare('DELETE FROM sites WHERE domain = ?').run(domain);
}

export function addLog(domain, line, stream = 'stdout') {
  const db = getDb();
  return db.prepare('INSERT INTO spawn_logs (site_domain, line, stream) VALUES (?, ?, ?)').run(domain, line, stream);
}

export function getLogs(domain) {
  const db = getDb();
  return db.prepare('SELECT * FROM spawn_logs WHERE site_domain = ? ORDER BY id ASC').all(domain);
}
