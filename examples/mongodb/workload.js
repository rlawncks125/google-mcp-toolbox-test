const appDb = db.getSiblingDB(process.env.MONGO_INITDB_DATABASE || "app");
const orders = appDb.observability_demo_orders;

if (orders.estimatedDocumentCount() < 10000) {
  void orders.deleteMany({ demo: true });
  const batch = [];
  for (let value = 1; value <= 10000; value += 1) {
    batch.push({
      demo: true,
      orderId: value,
      customerId: (value % 1000) + 1,
      status: ["pending", "paid", "shipped", "cancelled"][value % 4],
      amount: (value % 50000) / 100,
      score: (value * 7919) % 10000,
      createdAt: new Date(Date.now() - (value % 86400) * 1000)
    });
  }
  void orders.insertMany(batch, { ordered: false });
}

for (let run = 0; run < 20; run += 1) {
  void orders.find({ status: "pending", score: { $gte: run } })
    .sort({ score: -1 })
    .limit(100)
    .toArray();

  void orders.aggregate([
    { $match: { demo: true } },
    { $group: { _id: "$status", total: { $sum: "$amount" }, count: { $sum: 1 } } },
    { $sort: { total: -1 } }
  ]).toArray();
}

void orders.updateMany(
  { demo: true, orderId: { $lte: 100 } },
  { $set: { dashboardTestedAt: new Date() } }
);

printjson({
  collection: orders.getName(),
  documents: orders.estimatedDocumentCount(),
  note: "Standalone MongoDB does not support multi-document transactions; operation metrics were generated."
});
