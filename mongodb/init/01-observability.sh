#!/usr/bin/env bash
set -euo pipefail

mongosh --quiet \
  --username "$MONGO_INITDB_ROOT_USERNAME" \
  --password "$MONGO_INITDB_ROOT_PASSWORD" \
  --authenticationDatabase admin <<'EOJS'
const databaseName = process.env.MONGO_INITDB_DATABASE;
const adminDb = db.getSiblingDB("admin");

if (!adminDb.getUser(process.env.MONGO_TOOLBOX_USER)) {
  adminDb.createUser({
    user: process.env.MONGO_TOOLBOX_USER,
    pwd: process.env.MONGO_TOOLBOX_PASSWORD,
    roles: [
      { role: "clusterMonitor", db: "admin" },
      { role: "read", db: databaseName }
    ]
  });
}

const applicationDb = db.getSiblingDB(databaseName);
applicationDb.health_events.createIndex({ createdAt: -1 });
applicationDb.health_events.updateOne(
  { component: "bootstrap" },
  {
    $set: {
      status: "ok",
      component: "bootstrap",
      createdAt: new Date()
    }
  },
  { upsert: true }
);
EOJS
