// TrackerModel.js
//
// Pure logic for johnl404.parcel-tracker: status canonicalization,
// per-provider rate-limit and backoff math, relative-time formatting,
// display sorting, and archive pruning. No QML, no I/O — smoke-tested
// standalone under node.

// Canonical statuses. Every provider's raw event text is mapped into one of
// these so the rest of the plugin (icons, sorting, notifications, archive)
// only ever deals with this vocabulary.
var STATUSES = [
  "InfoReceived", "InTransit", "OutForDelivery",
  "Delivered", "Exception", "Returned", "Expired", "Unknown"
]

// Display order for the list: the things you act on float to the top,
// finished or broken things sink.
var STATUS_RANK = {
  OutForDelivery: 0,
  Exception: 1,
  InTransit: 2,
  InfoReceived: 3,
  Unknown: 4,
  Returned: 5,
  Expired: 6,
  Delivered: 7
}

var STATUS_LABELS = {
  InfoReceived: "Info received",
  InTransit: "In transit",
  OutForDelivery: "Out for delivery",
  Delivered: "Delivered",
  Exception: "Exception",
  Returned: "Returned",
  Expired: "Expired",
  Unknown: "Unknown"
}

// Statuses worth a desktop notification when a package lands on them.
var NOTIFIABLE_STATUSES = ["OutForDelivery", "Delivered", "Exception", "Returned"]

// Map raw provider text ("Delivered - Left at front door") to a canonical
// status. Keyword rules ordered most-specific first.
function canonicalize(rawLabel) {
  var label = String(rawLabel || "").toLowerCase()
  if (!label) return "Unknown"

  if (/out for delivery|out_for_delivery|on delivery vehicle|with delivery courier|courier has been assigned/.test(label))
    return "OutForDelivery"
  if (/delivered|delivery complete|left at|posted through|in your letterbox|signed for|successfully delivered/.test(label))
    return "Delivered"
  if (/return(ed)? to sender|being returned|returned to shipper/.test(label))
    return "Returned"
  if (/exception|failed|undeliverable|delivery attempted|refused|damaged|held in customs|customs clearance delay|address issue/.test(label))
    return "Exception"
  if (/expired|untrackable|no tracking record|not found|invalid tracking/.test(label))
    return "Expired"
  if (/info received|label created|pre-transit|shipping information received|electronic notification|awaiting item/.test(label))
    return "InfoReceived"
  if (/in transit|transit|departed|arrived|processed|accepted|sorted|scanned|origin|destination|customs|customs cleared|cleared|import|export|forwarded|dispatched|loaded|unloaded|plane|flight|facility|warehouse|picked up|collected/.test(label))
    return "InTransit"

  return "Unknown"
}

// Next check time with exponential backoff on consecutive failures.
// failures: consecutive failure count; intervalSec: provider base limit.
// Cap the delay at 4h so a broken endpoint never disappears for a day.
function computeNextCheckAt(failures, intervalSec, nowSec) {
  var f = Math.max(0, failures | 0)
  var mult = Math.pow(2, Math.min(f, 4))
  var delay = Math.min(intervalSec * mult, 4 * 3600)
  return (nowSec | 0) + delay
}

// Manual refresh is allowed only once the per-provider interval has elapsed
// since the last attempt — successful or not. This is the single gate both
// the scheduler and the refresh buttons go through.
function canRefreshNow(lastAttemptAt, intervalSec, nowSec) {
  return (nowSec | 0) >= ((lastAttemptAt | 0) + (intervalSec | 0))
}

// Seconds until the next attempt is allowed (0 when already allowed).
function secondsUntilRefresh(lastAttemptAt, intervalSec, nowSec) {
  var remaining = (lastAttemptAt | 0) + (intervalSec | 0) - (nowSec | 0)
  return remaining > 0 ? remaining : 0
}

function relativeTime(sec, nowSec) {
  sec = sec | 0
  nowSec = nowSec | 0
  var diff = nowSec - sec
  var future = diff < 0
  diff = Math.abs(diff)

  var text
  if (diff < 45) text = "just now"
  else if (diff < 3600) text = Math.round(diff / 60) + "m"
  else if (diff < 86400) text = Math.round(diff / 3600) + "h"
  else text = Math.round(diff / 86400) + "d"

  if (text === "just now") return text
  return future ? "in " + text : text + " ago"
}

// Clean up a tracking number as typed: trim, uppercase, strip separators
// people paste in (spaces, dashes, dots).
function normalizeNumber(raw) {
  return String(raw || "").toUpperCase().replace(/[\s\-\.]/g, "").trim()
}

function makeId(nowMs) {
  return ((nowMs || new Date().getTime()).toString(36)) + Math.random().toString(36).slice(2, 8)
}

// Display sort: status rank first, then most-recent-event first. Delivered
// and archived items end up at the bottom naturally via their rank.
function sortPackages(list) {
  var copy = list.slice()
  copy.sort(function(a, b) {
    var ra = STATUS_RANK[a.status] !== undefined ? STATUS_RANK[a.status] : STATUS_RANK.Unknown
    var rb = STATUS_RANK[b.status] !== undefined ? STATUS_RANK[b.status] : STATUS_RANK.Unknown
    if (ra !== rb) return ra - rb
    return (b.lastEventAt | 0) - (a.lastEventAt | 0)
  })
  return copy
}

// Drop packages that were delivered (or expired/returned) more than
// archiveDays ago. Returns the surviving list and whether anything changed.
function pruneArchived(packages, nowSec, archiveDays) {
  var cutoff = (nowSec | 0) - archiveDays * 86400
  var keep = []
  var changed = false
  for (var i = 0; i < packages.length; i++) {
    var p = packages[i]
    var done = p.status === "Delivered" || p.status === "Returned" || p.status === "Expired"
    if (done && ((p.lastEventAt | 0) > 0 ? p.lastEventAt : p.addedAt | 0) < cutoff) {
      changed = true
      continue
    }
    keep.push(p)
  }
  return { packages: keep, changed: changed }
}

// Count of packages still moving (or stuck) — what the bar pill shows.
function activeCount(packages) {
  var n = 0
  for (var i = 0; i < packages.length; i++)
    if (packages[i].status !== "Delivered" && packages[i].status !== "Returned" && packages[i].status !== "Expired") n++
  return n
}

function notifiable(status) {
  return NOTIFIABLE_STATUSES.indexOf(status) !== -1
}

// 17track's primary tracking-status enum, mapped into canonical statuses.
// Values per the official v2.2 API: 0 info received, 10 in transit,
// 20 exp/clearance, 30 pickup, 35 out for delivery, 40 delivered,
// 50 exception, 60 returned.
var TRACK_STATUS_MAP = {
  0: "InfoReceived", 10: "InTransit", 20: "InTransit", 30: "InTransit",
  35: "OutForDelivery", 40: "Delivered", 50: "Exception", 60: "Returned"
}

function canonicalFromTrackEnum(e) {
  return TRACK_STATUS_MAP[e | 0] || "Unknown"
}

if (typeof module !== "undefined") {
  module.exports = {
    STATUSES: STATUSES,
    STATUS_RANK: STATUS_RANK,
    STATUS_LABELS: STATUS_LABELS,
    TRACK_STATUS_MAP: TRACK_STATUS_MAP,
    canonicalFromTrackEnum: canonicalFromTrackEnum,
    canonicalize: canonicalize,
    computeNextCheckAt: computeNextCheckAt,
    canRefreshNow: canRefreshNow,
    secondsUntilRefresh: secondsUntilRefresh,
    relativeTime: relativeTime,
    normalizeNumber: normalizeNumber,
    makeId: makeId,
    sortPackages: sortPackages,
    pruneArchived: pruneArchived,
    activeCount: activeCount,
    notifiable: notifiable
  }
}
