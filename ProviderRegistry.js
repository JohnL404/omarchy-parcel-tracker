// ProviderRegistry.js
//
// Catalog of shipping providers for johnl404.parcel-tracker.
//
// Each provider entry describes:
//   id            stable provider id (also used in the saved state file)
//   name          display name
//   rateLimitSec  minimum seconds between refresh attempts (success or not)
//   patterns      tracking-number regexes with a 0..1 confidence; detection
//                 ranks providers by the best matching confidence
//   trackingUrl   deep link into the carrier's own tracking page
//   fetch         null for deep-link-only providers, otherwise a request
//                 spec the refresh engine turns into a curl command:
//                   { url, method, headers, body }
//                 url/body may be functions of the tracking number.
//   note          shown in the UI when fetch is null
//
// Privacy model: direct providers talk only to the carrier that owns the
// shipment. The one aggregator (17track) is opt-in and sees every number
// passed through it; it is never used unless the user enables it.

var universalUrl = "https://t.17track.net/en#nums="

// UPU S10 operator map: the two-letter suffix of an S10 code
// (e.g. LJ123456789US) is the origin country's ISO code. Every S10 number
// suggests the postal operator of its origin country.
var s10OperatorNames = {
  US: "USPS", GB: "Royal Mail", DE: "Deutsche Post", CA: "Canada Post",
  AU: "Australia Post", FR: "La Poste", NL: "PostNL", IT: "Poste Italiane",
  ES: "Correos España", CH: "Swiss Post", SE: "PostNord", DK: "PostNord",
  NO: "Posten Bring", FI: "Posti", BE: "bpost", AT: "Österreichische Post",
  PL: "Poczta Polska", PT: "CTT", IE: "An Post", CZ: "Česká pošta",
  SK: "Slovenská pošta", HU: "Magyar Posta", RO: "Poșta Română",
  GR: "Hellenic Post", TR: "PTT", RU: "Russian Post", UA: "Ukrposhta",
  JP: "Japan Post", KR: "Korea Post", CN: "China Post", HK: "Hongkong Post",
  TW: "Chunghwa Post", SG: "SingPost", MY: "Pos Malaysia", TH: "Thailand Post",
  VN: "Vietnam Post", PH: "PHLPost", IN: "India Post", LK: "Sri Lanka Post",
  PK: "Pakistan Post", NZ: "NZ Post", BR: "Correios", AR: "Correo Argentino",
  CL: "Correos de Chile", MX: "Correos de México", AE: "Emirates Post",
  SA: "Saudi Post", IL: "Israel Post", ZA: "SAPO", EG: "Egypt Post",
  MA: "Barid Al-Maghrib", IS: "Iceland Post", EE: "Omniva",
  LV: "Latvijas Pasts", LT: "Lietuvos paštas", SI: "Pošta Slovenije",
  HR: "Hrvatska pošta", BG: "Bulgarian Posts", CY: "Cyprus Post",
  MT: "MaltaPost", LU: "Luxembourg Post"
}

// Deep links for S10 operators whose tracking pages are stable and public.
// Operators missing here fall back to the universal tracker page.
var s10OperatorUrls = {
  US: "https://tools.usps.com/go/TrackConfirmAction?tLabels=",
  GB: "https://www.royalmail.com/track-your-item#/tracking-results/",
  DE: "https://www.deutschepost.de/sendung/simpleQuery.html?piececode=",
  CA: "https://www.canadapost-postescanada.ca/track-reperage/en#/details/",
  AU: "https://auspost.com.au/mypost/track/#/details/",
  FR: "https://www.laposte.fr/outils/suivre-vos-envois?code=",
  NL: "https://www.postnl.nl/track-en-trace/",
  IT: "https://www.poste.it/cerca/index.html#/risultati-spedizioni/",
  ES: "https://www.correos.es/es/es/herramientas/localizador/consultar?codigo=",
  CH: "https://www.post.ch/en/track-and-trace?trackId=",
  SE: "https://www.postnord.se/vara-verktyg/spara-och-fraga-paket/track-and-trace?shipmentId=",
  DK: "https://www.postnord.dk/vara-værktøjer/track-and-trace?shipmentId=",
  FI: "https://www.posti.fi/seuraan/shopper#!/shipment/",
  BE: "https://track.bpost.be/btr/web/#/search?itemCode=",
  JP: "https://trackings.post.japanpost.jp/services/srv/search/direct?tracking_no1=",
  CN: "https://english.ems.com.cn/queryWebsiteBillDaoAction.do?mailNum=",
  HK: "https://www.hongkongpost.hk/en/tracking/index.html?track=",
  SG: "https://www.singpost.com/track-items?track_number=",
  NZ: "https://www.nzpost.co.nz/tools/tracking?tno=",
  IN: "https://www.indiapost.gov.in/_layouts/15/dop.portal.tracking/trackconsignment.aspx?awb=",
  BR: "https://rastreamento.correios.com.br/app/index.php?objeto=",
  KR: "https://service.koreapost.go.kr/isposta/Common/InquiryService.do?sid1="
}

function s10Url(suffix, num) {
  var base = s10OperatorUrls[suffix]
  return base ? base + encodeURIComponent(num) : universalUrl + encodeURIComponent(num)
}

// Build the provider record for an S10 operator on demand. Rate limit is
// deliberately polite: these are unofficial requests to postal sites.
function s10Provider(suffix) {
  return {
    id: "s10-" + suffix,
    name: s10OperatorNames[suffix] || "UPU postal (" + suffix + ")",
    rateLimitSec: 900,
    patterns: [],
    trackingUrl: function(num) { return s10Url(suffix, num) },
    fetch: null,
    note: "Carrier blocks automated access (verified) — deep link only, or the opt-in aggregator."
  }
}

// Generic S10 provider for country codes we do not know an operator for.
function genericS10Provider(suffix) {
  return {
    id: "s10-" + suffix,
    name: "UPU postal (" + suffix + ")",
    rateLimitSec: 900,
    patterns: [],
    trackingUrl: function(num) { return universalUrl + encodeURIComponent(num) },
    fetch: null,
    note: "Unknown postal operator — universal tracker page, or enable the opt-in aggregator."
  }
}

var providers = [
  {
    id: "ups",
    name: "UPS",
    rateLimitSec: 1800,
    patterns: [{ re: "^1Z[0-9A-Z]{16}$", confidence: 0.97 }],
    trackingUrl: function(num) { return "https://www.ups.com/track?tracknum=" + encodeURIComponent(num) },
    fetch: null,
    note: "Carrier blocks automated access (verified) — deep link only, or the opt-in aggregator."
  },
  {
    id: "fedex",
    name: "FedEx",
    rateLimitSec: 1800,
    patterns: [
      { re: "^(96|62)\\d{18}$", confidence: 0.85 },
      { re: "^\\d{15}$", confidence: 0.8 },
      { re: "^\\d{12}$", confidence: 0.75 },
      { re: "^\\d{20}$", confidence: 0.6 }
    ],
    trackingUrl: function(num) { return "https://www.fedex.com/fedextrack/?trknbr=" + encodeURIComponent(num) },
    fetch: null,
    note: "Carrier blocks automated access (verified) — deep link only, or the opt-in aggregator."
  },
  {
    id: "usps",
    name: "USPS",
    rateLimitSec: 900,
    patterns: [
      { re: "^(92|93|94|95)\\d{18,20}$", confidence: 0.9 },
      { re: "^420\\d{5,9}\\d{20,22}$", confidence: 0.88 },
      { re: "^82\\d{20}$", confidence: 0.85 }
    ],
    trackingUrl: function(num) { return "https://tools.usps.com/go/TrackConfirmAction?tLabels=" + encodeURIComponent(num) },
    fetch: null,
    note: "Carrier blocks automated access (verified) — deep link only, or the opt-in aggregator."
  },
  {
    id: "dhl-express",
    name: "DHL Express",
    rateLimitSec: 1800,
    patterns: [{ re: "^\\d{10}$", confidence: 0.7 }],
    trackingUrl: function(num) { return "https://www.dhl.com/en/express/tracking.html?AWB=" + encodeURIComponent(num) },
    fetch: null,
    note: "Carrier blocks automated access (verified) — deep link only, or the opt-in aggregator."
  },
  {
    id: "dhl-ecommerce",
    name: "DHL eCommerce",
    rateLimitSec: 900,
    patterns: [
      { re: "^(GM|LX|RX)\\d{10,12}$", confidence: 0.8 },
      { re: "^(GM|LX|RX)\\d{16}$", confidence: 0.8 }
    ],
    trackingUrl: function(num) { return "https://webtrack.dhlglobalmail.com/?trackingnumber=" + encodeURIComponent(num) },
    fetch: null,
    note: "Carrier blocks automated access (verified) — deep link only, or the opt-in aggregator."
  },
  {
    id: "amazon",
    name: "Amazon Logistics",
    rateLimitSec: 3600,
    patterns: [
      { re: "^TBA\\d{12}$", confidence: 0.98 },
      { re: "^TBC\\d{12}$", confidence: 0.9 },
      { re: "^TBZ\\d{12}$", confidence: 0.85 }
    ],
    trackingUrl: function(num) { return "https://track.amazon.com/tracking/" + encodeURIComponent(num) },
    fetch: null,
    note: "Amazon has no public tracking endpoint — deep link only."
  },
  {
    id: "ontrac",
    name: "OnTrac",
    rateLimitSec: 1800,
    patterns: [{ re: "^[CD]\\d{14}$", confidence: 0.85 }],
    trackingUrl: function(num) { return "https://www.ontrac.com/tracking/?number=" + encodeURIComponent(num) },
    fetch: null,
    note: "Carrier blocks automated access (verified) — deep link only, or the opt-in aggregator."
  },
  {
    id: "lasership",
    name: "LaserShip",
    rateLimitSec: 1800,
    patterns: [{ re: "^[LS]\\d{8,12}$", confidence: 0.8 }],
    trackingUrl: function(num) { return "https://www.lasership.com/track/" + encodeURIComponent(num) },
    fetch: null,
    note: "Carrier blocks automated access (verified) — deep link only, or the opt-in aggregator."
  },
  {
    id: "evri",
    name: "Evri",
    rateLimitSec: 900,
    patterns: [
      { re: "^H\\d{15}$", confidence: 0.85 },
      { re: "^\\d{16}$", confidence: 0.55 }
    ],
    trackingUrl: function(num) { return "https://www.evri.com/track/" + encodeURIComponent(num) },
    fetch: null,
    note: "Carrier blocks automated access (verified) — deep link only, or the opt-in aggregator."
  },
  {
    id: "yanwen",
    name: "Yanwen",
    rateLimitSec: 900,
    patterns: [
      { re: "^YT\\d{13}$", confidence: 0.85 },
      { re: "^(YD|YP)\\d{13}$", confidence: 0.7 }
    ],
    trackingUrl: function(num) { return universalUrl + encodeURIComponent(num) },
    fetch: null,
    note: "Carrier blocks automated access (verified) — deep link only, or the opt-in aggregator."
  },
  {
    id: "4px",
    name: "4PX",
    rateLimitSec: 900,
    patterns: [
      { re: "^LP\\d{13}$", confidence: 0.8 },
      { re: "^EQ\\d{12,14}$", confidence: 0.55 }
    ],
    trackingUrl: function(num) { return universalUrl + encodeURIComponent(num) },
    fetch: null,
    note: "Carrier blocks automated access (verified) — deep link only, or the opt-in aggregator."
  },
  {
    id: "sf-express",
    name: "SF Express",
    rateLimitSec: 900,
    patterns: [{ re: "^SF\\d{13,15}$", confidence: 0.9 }],
    trackingUrl: function(num) { return "https://www.sf-express.com/en/global/waybill/waybill-detail/" + encodeURIComponent(num) },
    fetch: null,
    note: "Carrier blocks automated access (verified) — deep link only, or the opt-in aggregator."
  },
  {
    id: "purolator",
    name: "Purolator",
    rateLimitSec: 1800,
    patterns: [{ re: "^\\d{12,14}$", confidence: 0.35 }],
    trackingUrl: function(num) { return "https://www.purolator.com/en/shipping/tracking-details?pin=" + encodeURIComponent(num) },
    fetch: null,
    note: "Carrier blocks automated access (verified) — deep link only, or the opt-in aggregator."
  },
  {
    id: "dpd",
    name: "DPD",
    rateLimitSec: 900,
    patterns: [{ re: "^\\d{14}$", confidence: 0.35 }],
    trackingUrl: function(num) { return "https://www.dpd.com/tracking/" + encodeURIComponent(num) },
    fetch: null,
    note: "Carrier blocks automated access (verified) — deep link only, or the opt-in aggregator."
  },
  {
    id: "gls",
    name: "GLS",
    rateLimitSec: 900,
    patterns: [{ re: "^\\d{11,13}$", confidence: 0.3 }],
    trackingUrl: function(num) { return "https://gls-group.com/en/parcel-tracking/?match=" + encodeURIComponent(num) },
    fetch: null,
    note: "Carrier blocks automated access (verified) — deep link only, or the opt-in aggregator."
  },
  {
    id: "17track",
    name: "17track (aggregator)",
    rateLimitSec: 3600,
    aggregator: true,
    patterns: [],
    trackingUrl: function(num) { return universalUrl + encodeURIComponent(num) },
    // Official keyed API (api.17track.net), per the user's own free/paid
    // account. Two-step flow: /register is a no-op for already-known
    // numbers, /gettrackinfo returns the full event timeline. The engine
    // expands {num}/{apiKey} from the package and settings.
    fetch: {
      keyRequired: true,
      steps: [
        {
          url: "https://api.17track.net/track/v2.2/register",
          method: "POST",
          headers: ["17token:{apiKey}", "Content-Type: application/json"],
          body: "[{\"number\":\"{num}\"}]"
        },
        {
          url: "https://api.17track.net/track/v2.2/gettrackinfo",
          method: "POST",
          headers: ["17token:{apiKey}", "Content-Type: application/json"],
          body: "[{\"number\":\"{num}\"}]"
        }
      ],
      parse: "17track"
    },
    note: "Opt-in aggregator. Enabled with your own API key in settings. 17track sees every number you track through it."
  },
  {
    id: "other",
    name: "Other / unknown",
    rateLimitSec: 900,
    patterns: [],
    trackingUrl: function(num) { return universalUrl + encodeURIComponent(num) },
    fetch: null,
    note: "Provider unknown — universal tracker page, or pick a provider explicitly."
  }
]

function providerById(id) {
  if (typeof id !== "string" || !id) return null
  if (id.indexOf("s10-") === 0) {
    var suffix = id.slice(4).toUpperCase()
    if (s10OperatorNames[suffix]) return s10Provider(suffix)
    if (/^[A-Z]{2}$/.test(suffix)) return genericS10Provider(suffix)
    return null
  }
  for (var i = 0; i < providers.length; i++)
    if (providers[i].id === id) return providers[i]
  return null
}

function providerName(id) {
  var p = providerById(id)
  return p ? p.name : id
}

// Rank tracking-number suggestions for a number. Returns a list of
// { providerId, name, confidence } sorted best-first. Ambiguous formats
// (e.g. bare digit runs) yield several lower-confidence candidates so the
// add flow can offer a choice.
function detect(number) {
  var num = String(number || "").trim().toUpperCase()
  if (!num) return []

  var out = []

  // S10: two letters, nine digits, two-letter country suffix.
  var s10 = /^([A-Z]{2})\d{9}([A-Z]{2})$/.exec(num)
  if (s10) {
    var suffix = s10[2]
    out.push({
      providerId: s10OperatorNames[suffix] ? "s10-" + suffix : "s10-XX",
      name: s10OperatorNames[suffix] || "UPU postal (" + suffix + ")",
      confidence: 0.95
    })
  }

  for (var i = 0; i < providers.length; i++) {
    var p = providers[i]
    for (var j = 0; j < p.patterns.length; j++) {
      try {
        if (new RegExp(p.patterns[j].re).test(num)) {
          out.push({ providerId: p.id, name: p.name, confidence: p.patterns[j].confidence })
          break
        }
      } catch (e) { /* malformed pattern in registry: skip */ }
    }
  }

  out.sort(function(a, b) { return b.confidence - a.confidence })
  return out
}

// Every selectable provider for the add-flow override list: static entries
// (minus the meta "other") plus the S10 operators as a compact group entry.
function selectableProviders() {
  var list = []
  for (var i = 0; i < providers.length; i++) {
    var p = providers[i]
    if (p.id === "other") continue
    list.push({ providerId: p.id, name: p.name, group: p.aggregator ? "Aggregator (opt-in)" : "Carriers" })
  }
  list.push({ providerId: "other", name: "Other / unknown", group: "Carriers" })
  return list
}

if (typeof module !== "undefined") {
  module.exports = {
    providers: providers,
    universalUrl: universalUrl,
    s10OperatorNames: s10OperatorNames,
    detect: detect,
    providerById: providerById,
    providerName: providerName,
    selectableProviders: selectableProviders,
    s10Provider: s10Provider
  }
}
