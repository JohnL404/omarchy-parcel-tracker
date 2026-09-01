const assert = require("node:assert")
const path = require("node:path")
const Registry = require(path.join(__dirname, "..", "ProviderRegistry.js"))
const Model = require(path.join(__dirname, "..", "TrackerModel.js"))

// ---- Detection
function first(number) { return Registry.detect(number)[0] }

assert.equal(first("1Z999AA10123456784").providerId, "ups", "UPS 1Z")
assert.equal(first("TBA123456789012").providerId, "amazon", "Amazon TBA")
assert.equal(first("LJ123456789US").providerId, "s10-US", "S10 -> USPS")
assert.equal(first("LJ123456789GB").providerId, "s10-GB", "S10 -> Royal Mail")
assert.equal(first("LJ123456789ZZ").name, "UPU postal (ZZ)", "unknown S10 origin")
assert.equal(first("9400111899223344556677").providerId, "usps", "USPS IMpb")
assert.equal(first("4201234567894000111899223344556").providerId, "usps", "USPS with postal prefix")
assert.equal(first("SF1234567890123").providerId, "sf-express", "SF Express")
assert.equal(first("YT1234567890123").providerId, "yanwen", "Yanwen")
assert.equal(first("H123456789012345").providerId, "evri", "Evri")

// Ambiguous formats produce ranked alternatives
const twelve = Registry.detect("123456789012")
assert.ok(twelve.length > 1, "12-digit yields alternatives")
assert.equal(twelve[0].providerId, "fedex", "12-digit best guess FedEx")

const ten = Registry.detect("1234567890")
assert.equal(ten[0].providerId, "dhl-express", "10-digit best guess DHL Express")

// S10 beats bare patterns
assert.equal(Registry.detect("RB123456789DE")[0].confidence, 0.95)

// Normalization
assert.equal(Model.normalizeNumber(" 1z 999-aa10.1234 56784 "), "1Z999AA10123456784")
assert.deepEqual(Registry.detect(Model.normalizeNumber("1z999aa10123456784"))[0], first("1Z999AA10123456784"))

// ---- providerById incl. synthetic S10
assert.equal(Registry.providerById("ups").name, "UPS")
assert.equal(Registry.providerById("s10-DE").name, "Deutsche Post")
assert.ok(Registry.providerById("s10-DE").trackingUrl("RB123456789DE").includes("RB123456789DE"))
assert.ok(Registry.providerById("s10-GB").trackingUrl("X").includes("royalmail"))
assert.equal(Registry.providerById("s10-ZZ").trackingUrl("X"), Registry.universalUrl + "X")
assert.equal(Registry.providerById("nope"), null)

// selectable list: has carriers + aggregator + other, no synthetic s10 dupes
const selectable = Registry.selectableProviders()
assert.ok(selectable.some(p => p.providerId === "17track"))
assert.ok(selectable.some(p => p.providerId === "other"))
assert.ok(!selectable.some(p => p.providerId.startsWith("s10-")))

// ---- canonicalize
assert.equal(Model.canonicalize("Out for delivery -今日配達予定"), "OutForDelivery")
assert.equal(Model.canonicalize("Delivered - Left at front door"), "Delivered")
assert.equal(Model.canonicalize("DELIVERY ATTEMPTED - NO ANSWER"), "Exception")
assert.equal(Model.canonicalize("Item returned to sender"), "Returned")
assert.equal(Model.canonicalize("Shipping information received by carrier"), "InfoReceived")
assert.equal(Model.canonicalize("Departed facility in Zhengzhou"), "InTransit")
assert.equal(Model.canonicalize("Customs clearance completed"), "InTransit")
assert.equal(Model.canonicalize(""), "Unknown")

// ---- rate limits & backoff
const NOW = 1_756_600_000
assert.ok(Model.canRefreshNow(NOW - 1801, 1800, NOW), "past interval allows refresh")
assert.ok(!Model.canRefreshNow(NOW - 1799, 1800, NOW), "within interval blocks refresh")
assert.equal(Model.secondsUntilRefresh(NOW - 1000, 1800, NOW), 800)
assert.equal(Model.secondsUntilRefresh(NOW - 5000, 1800, NOW), 0)

assert.equal(Model.computeNextCheckAt(0, 900, NOW), NOW + 900, "success: base interval")
assert.equal(Model.computeNextCheckAt(1, 900, NOW), NOW + 1800, "one failure: 2x")
assert.equal(Model.computeNextCheckAt(3, 900, NOW), NOW + 7200, "three failures: 8x")
assert.equal(Model.computeNextCheckAt(10, 900, NOW), NOW + 4 * 3600, "backoff capped at 4h")

// ---- relative time
assert.equal(Model.relativeTime(NOW - 10, NOW), "just now")
assert.equal(Model.relativeTime(NOW - 120, NOW), "2m ago")
assert.equal(Model.relativeTime(NOW - 7200, NOW), "2h ago")
assert.equal(Model.relativeTime(NOW - 3 * 86400, NOW), "3d ago")
assert.equal(Model.relativeTime(NOW + 300, NOW), "in 5m")

// ---- sort: OutForDelivery first, Delivered last, recency within rank
const pkgs = [
  { status: "Delivered", lastEventAt: NOW - 100 },
  { status: "InTransit", lastEventAt: NOW - 100 },
  { status: "InTransit", lastEventAt: NOW - 50 },
  { status: "OutForDelivery", lastEventAt: NOW - 999 }
]
const sorted = Model.sortPackages(pkgs)
assert.equal(sorted[0].status, "OutForDelivery")
assert.equal(sorted[1].lastEventAt, NOW - 50, "recency within rank")
assert.equal(sorted[3].status, "Delivered")

// ---- prune
const archived = Model.pruneArchived([
  { status: "Delivered", lastEventAt: NOW - 20 * 86400, addedAt: NOW - 30 * 86400 },
  { status: "Delivered", lastEventAt: NOW - 2 * 86400 },
  { status: "InTransit", lastEventAt: NOW - 40 * 86400 }
], NOW, 14)
assert.equal(archived.packages.length, 2)
assert.ok(archived.changed)
assert.equal(Model.pruneArchived([{ status: "InTransit", lastEventAt: 1 }], NOW, 14).changed, false)
assert.equal(Model.pruneArchived([{ status: "Delivered", lastEventAt: 0, addedAt: NOW - 20 * 86400 }], NOW, 14).changed, true, "falls back to addedAt when no event time")

// ---- misc
assert.equal(Model.activeCount([{ status: "Delivered" }, { status: "InTransit" }, { status: "Exception" }]), 2)

// ---- route stops (unique, chronological, oldest first)
assert.deepEqual(Model.routeStops([]), [])
assert.deepEqual(Model.routeStops([{ loc: "" }, { loc: "  " }]), [])
assert.deepEqual(
  Model.routeStops([
    { t: 3, loc: "Brooklyn, NY" },
    { t: 2, loc: "Frankfurt" },
    { t: 1, loc: "Hamburg" },
    { t: 0, loc: "Frankfurt" }
  ]),
  ["Frankfurt", "Hamburg", "Brooklyn, NY"]
)
assert.deepEqual(Model.routeStops([{ loc: "Only one" }]), ["Only one"])
assert.ok(Model.notifiable("Delivered") && Model.notifiable("OutForDelivery"))
assert.ok(!Model.notifiable("InTransit"))
assert.match(Model.makeId(), /^[0-9a-z]+$/)

// ---- 17track enum mapping
assert.equal(Model.canonicalFromTrackEnum(40), "Delivered")
assert.equal(Model.canonicalFromTrackEnum(35), "OutForDelivery")
assert.equal(Model.canonicalFromTrackEnum(20), "InTransit")
assert.equal(Model.canonicalFromTrackEnum(60), "Returned")
assert.equal(Model.canonicalFromTrackEnum(50), "Exception")
assert.equal(Model.canonicalFromTrackEnum(999), "Unknown")

console.log("All tracker model + registry tests passed")
