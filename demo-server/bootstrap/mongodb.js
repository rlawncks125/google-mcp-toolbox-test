const appDb = db.getSiblingDB(process.env.MONGO_DATABASE);

if (!appDb.getUser(process.env.MONGO_APP_USER)) {
  appDb.createUser({
    user: process.env.MONGO_APP_USER,
    pwd: process.env.MONGO_APP_PASSWORD,
    roles: [{ role: "readWrite", db: process.env.MONGO_DATABASE }],
  });
} else {
  appDb.updateUser(process.env.MONGO_APP_USER, {
    pwd: process.env.MONGO_APP_PASSWORD,
    roles: [{ role: "readWrite", db: process.env.MONGO_DATABASE }],
  });
}

appDb.health_events.createIndex({ createdAt: -1 });
appDb.health_events.updateOne(
  { component: "demo-api" },
  { $set: { component: "demo-api", status: "ok", createdAt: new Date() } },
  { upsert: true },
);
