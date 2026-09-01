import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "TrackerModel.js" as Model
import "ProviderRegistry.js" as Registry

// Parcel Tracker panel: list, add flow, parcel detail, and settings,
// backed by a local state file and a rate-limited refresh engine.
//
// Privacy: the only automatic fetch path is the opt-in 17track aggregator
// using the user's own API key. Deep links always go to the carrier itself.
// Nothing else leaves the machine.
Panel {
  id: root
  moduleName: "johnl404.parcel-tracker"
  ipcTarget: "johnl404.parcel-tracker"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- Verified-in-font glyphs (nf-md), chosen for what each status means:
  //      barcode = label created, truck-fast = moving, truck-delivery =
  //      on the van, check = done, alert = problem, undo = sent back,
  //      timer-off = too old to track, help = we don't know.
  readonly property var statusGlyphs: ({
    "InfoReceived": "󰁱",
    "InTransit": "󰞈",
    "OutForDelivery": "󰔾",
    "Delivered": "󰗠",
    "Exception": "󰀨",
    "Returned": "󰕍",
    "Expired": "󱎬",
    "Unknown": "󰋗"
  })

  // ---- State
  property var pkgList: []
  property var prefs: ({ aggregatorEnabled: false, aggregatorKey: "", notify: true, archiveDays: 14 })
  property string viewMode: "list" // list | detail | add | settings
  property string selectedId: ""

  // Add flow
  property string addStep: "number" // number | provider | description
  property string addNumber: ""
  property var addSuggestions: []
  property int addSelected: 0
  property string addProvider: ""
  property string addDescription: ""

  // Detail extras
  property bool editingDescription: false
  property bool confirmingDelete: false

  // ---- Derived state the pill mirrors
  readonly property int activeCount: Model.activeCount(pkgList)
  readonly property bool urgent: {
    for (var i = 0; i < pkgList.length; i++) {
      var s = pkgList[i].status
      if (s === "OutForDelivery" || s === "Exception") return true
    }
    return false
  }
  readonly property bool errored: {
    for (var i = 0; i < pkgList.length; i++)
      if ((pkgList[i].lastError || "") !== "" && pkgList[i].status !== "Delivered") return true
    return false
  }

  readonly property var sortedActive: {
    var out = []
    for (var i = 0; i < pkgList.length; i++)
      if (pkgList[i].status !== "Delivered" && pkgList[i].status !== "Returned" && pkgList[i].status !== "Expired") out.push(pkgList[i])
    return Model.sortPackages(out)
  }
  readonly property var sortedFinished: {
    var out = []
    for (var i = 0; i < pkgList.length; i++)
      if (pkgList[i].status === "Delivered" || pkgList[i].status === "Returned" || pkgList[i].status === "Expired") out.push(pkgList[i])
    return Model.sortPackages(out)
  }

  function selectedPackage() {
    for (var i = 0; i < pkgList.length; i++)
      if (pkgList[i].id === selectedId) return pkgList[i]
    return null
  }

  // ============================= Store =============================

  property int lastSaveAt: 0

  function statePath() {
    return Quickshell.env("HOME") + "/.local/state/omarchy/plugins/parcel-tracker/packages.json"
  }

  function defaultPrefs() {
    return { aggregatorEnabled: false, aggregatorKey: "", notify: true, archiveDays: 14 }
  }

  function loadState(text) {
    var data = null
    try { data = JSON.parse(text || "{}") } catch (e) { data = null }
    if (!data || typeof data !== "object") data = {}

    var loaded = Array.isArray(data.packages) ? data.packages : []
    var mergedPrefs = defaultPrefs()
    if (data.settings && typeof data.settings === "object")
      for (var k in mergedPrefs) if (k in data.settings) mergedPrefs[k] = data.settings[k]

    var now = nowSec()
    var pruned = Model.pruneArchived(loaded, now, mergedPrefs.archiveDays | 0)

    prefs = mergedPrefs
    pkgList = pruned.packages
    if (pruned.changed) saveState()
  }

  function saveState() {
    lastSaveAt = new Date().getTime()
    storeFile.setText(JSON.stringify({ version: 1, settings: prefs, packages: pkgList }, null, 2) + "\n")
  }

  FileView {
    id: storeFile
    path: root.statePath()
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      // Ignore echoes of our own write landing through the file watcher.
      if (new Date().getTime() - root.lastSaveAt < 600) return
      root.loadState(text())
    }
    onLoadFailed: {
      if (new Date().getTime() - root.lastSaveAt < 600) return
      root.loadState("")
    }
    onFileChanged: reload()
  }

  // First read can race shell startup; one delayed reload self-corrects
  // (same pattern the built-in weather panel uses for its location file).
  Timer {
    interval: 1500
    running: true
    onTriggered: storeFile.reload()
  }

  function nowSec() {
    return Math.floor(new Date().getTime() / 1000)
  }

  // ========================= Refresh engine =========================
  //
  // One curl at a time, a queue, per-provider rate limits, exponential
  // backoff. Both the auto sweep and manual refresh go through the same
  // queue and the same Model.canRefreshNow gate.

  property var queue: []            // package ids waiting to refresh
  property bool fetching: false
  property string currentId: ""
  property var currentPkg: null
  property int currentStep: 0
  property string currentStdout: ""

  // Ticking seconds for time-based bindings (countdowns, relative labels).
  property int nowPulse: 0
  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowPulse = root.nowSec()
  }

  function resolveFetchSpec(pkg) {
    var provider = Registry.providerById(pkg.provider)
    if (provider && provider.fetch && !provider.aggregator) return provider.fetch
    // Aggregator path: opt-in, needs the user's own key.
    if (prefs.aggregatorEnabled && (prefs.aggregatorKey || "").length > 0) {
      var agg = Registry.providerById("17track")
      if (agg && agg.fetch) return agg.fetch
    }
    return null
  }

  function effectiveInterval(pkg) {
    if (!pkg) return 900
    var provider = Registry.providerById(pkg.provider)
    var viaAggregator = !(provider && provider.fetch && !provider.aggregator)
    if (viaAggregator) {
      var agg = Registry.providerById("17track")
      return agg ? agg.rateLimitSec : 3600
    }
    return provider ? provider.rateLimitSec : 900
  }

  function fetchAvailable(pkg) {
    if (!pkg) return false
    return resolveFetchSpec(pkg) !== null
  }

  function buildStepArgs(step, pkg) {
    var apiKey = String(prefs.aggregatorKey || "")
    var url = step.url
    var body = String(step.body).split("{num}").join(pkg.number).split("{apiKey}").join(apiKey)
    var args = ["curl", "-fsS", "--max-time", "12", "-X", step.method]
    for (var i = 0; i < step.headers.length; i++)
      args.push("-H", String(step.headers[i]).split("{apiKey}").join(apiKey))
    args.push("--data", body)
    args.push(url)
    return args
  }

  Timer {
    id: engineTimer
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.autoSweep()
  }

  // Polite gap between queued fetches.
  Timer {
    id: gapTimer
    interval: 2500
    onTriggered: root.pump()
  }

  function autoSweep() {
    var now = nowSec()
    var pruned = Model.pruneArchived(pkgList, now, prefs.archiveDays | 0)
    if (pruned.changed) {
      pkgList = pruned.packages
      saveState()
    }

    for (var i = 0; i < pkgList.length; i++) {
      var pkg = pkgList[i]
      if (!fetchAvailable(pkg)) continue
      var interval = effectiveInterval(pkg)
      if (now < (pkg.nextCheckAt | 0)) continue
      if (!Model.canRefreshNow(pkg.lastAttemptAt | 0, interval, now)) continue
      if (queue.indexOf(pkg.id) === -1 && pkg.id !== currentId) queue.push(pkg.id)
    }
    pump()
  }

  function pump() {
    if (fetching || queue.length === 0) return
    var pkg = null
    while (queue.length > 0) {
      var id = queue.shift()
      pkg = null
      for (var i = 0; i < pkgList.length; i++)
        if (pkgList[i].id === id) { pkg = pkgList[i]; break }
      if (pkg && fetchAvailable(pkg)) break
      pkg = null
    }
    if (!pkg) { if (queue.length > 0) gapTimer.restart(); return }

    currentId = pkg.id
    currentPkg = pkg
    currentStep = 0
    fetching = true
    // Debounce manual double-taps immediately; final values written on finish.
    pkg.lastAttemptAt = nowSec()
    startStep()
  }

  function startStep() {
    var spec = resolveFetchSpec(currentPkg)
    if (!spec || !spec.steps || currentStep >= spec.steps.length) {
      finishFetch()
      return
    }
    currentStdout = ""
    fetchProc.command = buildStepArgs(spec.steps[currentStep], currentPkg)
    fetchProc.running = true
  }

  Process {
    id: fetchProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.currentStdout = String(text || "")
    }

    onExited: function(exitCode) {
      root.handleStepResult(exitCode)
    }
  }

  function handleStepResult(exitCode) {
    var pkg = currentPkg
    if (!pkg) { fetching = false; return }

    if (exitCode !== 0) {
      failFetch(pkg, "Network error (curl exit " + exitCode + ")")
      return
    }

    var parsed = null
    try { parsed = JSON.parse(currentStdout) } catch (e) { parsed = null }

    if (currentStep === 0) {
      // /register: success or "already registered" both mean go ahead.
      if (!parsed || parsed.code !== 0) {
        failFetch(pkg, parsed ? "API error " + parsed.code : "Bad API response")
        return
      }
      var regRejected = rejectedEntry(parsed)
      if (regRejected && regRejected.error_code !== -18019901) {
        failFetch(pkg, regRejected.error_message || "Register failed")
        return
      }
      currentStep = 1
      startStep()
      return
    }

    // /gettrackinfo
    if (!parsed || parsed.code !== 0) {
      failFetch(pkg, parsed ? "API error " + parsed.code : "Bad API response")
      return
    }
    var accepted = acceptedEntryFor(parsed, pkg.number)
    if (!accepted) {
      var rejected = rejectedEntry(parsed)
      failFetch(pkg, rejected ? (rejected.error_message || "Tracking unavailable") : "Tracking unavailable")
      return
    }
    applyTrackInfo(pkg, accepted.track)
    succeedFetch(pkg)
  }

  function acceptedEntryFor(parsed, number) {
    var accepted = parsed.data && parsed.data.accepted ? parsed.data.accepted : []
    for (var i = 0; i < accepted.length; i++)
      if (String(accepted[i].number).toUpperCase() === String(number).toUpperCase())
        return accepted[i]
    return null
  }

  function rejectedEntry(parsed) {
    var rejected = parsed.data && parsed.data.rejected ? parsed.data.rejected : []
    return rejected.length > 0 ? rejected[0] : null
  }

  function parseEventTime(raw) {
    // 17track event times are "YYYY-MM-DD HH:MM" in local-origin time.
    // Good enough as-is: consistent within a package.
    var t = new Date(String(raw || "").replace(" ", "T") + ":00").getTime()
    return isNaN(t) ? 0 : Math.floor(t / 1000)
  }

  function applyTrackInfo(pkg, track) {
    var events = []
    var groups = ["z0", "z1"]
    for (var g = 0; g < groups.length; g++) {
      var list = track && track[groups[g]] ? track[groups[g]] : []
      for (var i = 0; i < list.length; i++)
        events.push({
          t: parseEventTime(list[i].a),
          label: String(list[i].z || ""),
          loc: String(list[i].c || "")
        })
    }
    events.sort(function(a, b) { return b.t - a.t })
    if (events.length > 60) events = events.slice(0, 60)

    var newStatus = "Unknown"
    if (track && track.e !== undefined && track.e !== null)
      newStatus = Model.canonicalFromTrackEnum(track.e)
    else if (events.length > 0)
      newStatus = Model.canonicalize(events[0].label)

    var previous = pkg.status
    pkg.events = events
    pkg.status = newStatus
    pkg.statusLabel = events.length > 0 ? events[0].label : "No tracking data yet"
    pkg.lastEvent = events.length > 0 ? events[0].label : ""
    pkg.lastEventAt = events.length > 0 ? events[0].t : 0

    if (previous !== newStatus && prefs.notify && Model.notifiable(newStatus))
      notifyStatus(pkg, newStatus)
  }

  function succeedFetch(pkg) {
    var now = nowSec()
    pkg.lastCheckedAt = now
    pkg.lastError = ""
    pkg.consecutiveFailures = 0
    pkg.nextCheckAt = Model.computeNextCheckAt(0, effectiveInterval(pkg), now)
    finishFetch()
  }

  function failFetch(pkg, message) {
    var now = nowSec()
    pkg.lastCheckedAt = now
    pkg.lastError = message
    pkg.consecutiveFailures = (pkg.consecutiveFailures | 0) + 1
    pkg.nextCheckAt = Model.computeNextCheckAt(pkg.consecutiveFailures | 0, effectiveInterval(pkg), now)
    finishFetch()
  }

  // In-place field mutations on plain JS objects are invisible to QML
  // bindings. Replacing the package's object identity re-fires every
  // binding that reads it (list rows, detail view, pill counts).
  function touchPackage(id) {
    pkgList = pkgList.map(function(p) {
      if (p.id !== id) return p
      var clone = {}
      for (var k in p) clone[k] = p[k]
      return clone
    })
  }

  function finishFetch() {
    var id = currentId
    currentId = ""
    currentPkg = null
    currentStep = 0
    fetching = false
    touchPackage(id)
    saveState()
    gapTimer.restart()
  }

  // Manual refresh: same queue, same gate. forceAll is the header
  // "refresh all" action; per-package refresh queues just one.
  function refreshPackage(id) {
    var pkg = null
    for (var i = 0; i < pkgList.length; i++)
      if (pkgList[i].id === id) { pkg = pkgList[i]; break }
    if (!pkg || fetching) return false
    if (!fetchAvailable(pkg)) return false
    if (!Model.canRefreshNow(pkg.lastAttemptAt | 0, effectiveInterval(pkg), nowSec())) return false
    if (queue.indexOf(id) !== -1) return false
    queue.push(id)
    pump()
    return true
  }

  function refreshAll(force) {
    var now = nowSec()
    var queuedAny = false
    for (var i = 0; i < pkgList.length; i++) {
      var pkg = pkgList[i]
      if (!fetchAvailable(pkg)) continue
      if (!Model.canRefreshNow(pkg.lastAttemptAt | 0, effectiveInterval(pkg), now)) continue
      if (queue.indexOf(pkg.id) !== -1) continue
      queue.push(pkg.id)
      queuedAny = true
    }
    if (queuedAny || force) pump()
  }

  // ========================= Notifications =========================

  function notifyStatus(pkg, status) {
    var titles = {
      "OutForDelivery": "Out for delivery",
      "Delivered": "Parcel delivered",
      "Exception": "Delivery exception",
      "Returned": "Parcel returned"
    }
    var body = (pkg.description || pkg.number) + " — " + (pkg.lastEvent || "")
    notify(titles[status] || "Parcel update", body)
  }

  function notify(title, body) {
    var bin = Quickshell.env("OMARCHY_PATH") + "/bin/omarchy-notification-send"
    Quickshell.execDetached([bin, String(title), String(body)])
  }

  // ========================= Packages CRUD =========================

  function addPackage() {
    var number = Model.normalizeNumber(addNumber)
    if (!number) return
    if (findPackage(number)) { viewMode = "detail"; selectedId = findPackage(number).id; resetAdd(); return }

    var provider = addProvider || (addSuggestions.length > 0 ? addSuggestions[0].providerId : "other")
    var now = nowSec()
    var pkg = {
      id: Model.makeId(),
      number: number,
      provider: provider,
      description: String(addDescription || "").trim(),
      addedAt: now,
      status: "InfoReceived",
      statusLabel: "",
      lastEvent: "",
      lastEventAt: 0,
      lastCheckedAt: 0,
      lastAttemptAt: 0,
      lastError: "",
      consecutiveFailures: 0,
      nextCheckAt: now,
      events: []
    }
    pkgList = pkgList.concat([pkg])
    saveState()
    resetAdd()
    viewMode = "list"
    if (fetchAvailable(pkg)) refreshPackage(pkg.id)
  }

  function findPackage(number) {
    number = Model.normalizeNumber(number)
    for (var i = 0; i < pkgList.length; i++)
      if (pkgList[i].number === number) return pkgList[i]
    return null
  }

  function removePackage(id) {
    var next = []
    for (var i = 0; i < pkgList.length; i++)
      if (pkgList[i].id !== id) next.push(pkgList[i])
    pkgList = next
    saveState()
  }

  function openTracking(pkg) {
    if (!pkg) return
    var provider = Registry.providerById(pkg.provider)
    var url = provider
      ? provider.trackingUrl(pkg.number)
      : Registry.universalUrl + encodeURIComponent(pkg.number)
    Qt.openUrlExternally(url)
  }

  // Route deep link: Google Maps directions from the oldest to the newest
  // event location. User-initiated browser navigation only — the shell
  // itself makes no request.
  function openRoute(pkg) {
    if (!pkg) return
    var stops = Model.routeStops(pkg.events)
    if (stops.length < 2) return
    var url = "https://www.google.com/maps/dir/?api=1&origin="
      + encodeURIComponent(stops[0])
      + "&destination=" + encodeURIComponent(stops[stops.length - 1])
    Qt.openUrlExternally(url)
  }

  function setDescription(id, text) {
    for (var i = 0; i < pkgList.length; i++)
      if (pkgList[i].id === id) pkgList[i].description = String(text || "").trim()
    touchPackage(id)
    saveState()
  }

  function setPrefs(values) {
    var next = {}
    for (var k in prefs) next[k] = prefs[k]
    for (var key in values) next[key] = values[key]
    prefs = next
    saveState()
  }

  function resetAdd() {
    addStep = "number"
    addNumber = ""
    addSuggestions = []
    addSelected = 0
    addProvider = ""
    addDescription = ""
  }

  // ============================ Panel ==============================

  function open() {
    root.controller.show()
  }

  function close() {
    if (root.editingDescription) root.editingDescription = false
    if (root.confirmingDelete) root.confirmingDelete = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function goBack() {
    if (viewMode === "detail") { viewMode = "list"; selectedId = ""; editingDescription = false; confirmingDelete = false }
    else if (viewMode === "add") {
      if (addStep === "number") { viewMode = "list"; resetAdd() }
      else if (addStep === "provider") addStep = "number"
      else addStep = "provider"
    }
    else if (viewMode === "settings") viewMode = "list"
  }

  function titleText() {
    if (viewMode === "add") return "Add parcel"
    if (viewMode === "settings") return "Settings"
    if (viewMode === "detail") {
      var pkg = selectedPackage()
      return pkg ? (pkg.description || pkg.number) : "Package"
    }
    return "Parcels"
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: false
      onCloseRequested: {
        if (viewMode !== "list") goBack()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: content
          width: parent.width
          spacing: Style.space(8)

          // ---- Header
          Item {
            width: parent.width
            height: Math.max(headerTitle.implicitHeight, Style.space(24))

            PanelActionButton {
              anchors.left: parent.left
              anchors.leftMargin: 0
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰅁" // chevron-left
              tooltipText: "Back"
              visible: viewMode !== "list"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: root.goBack()
            }

            Text {
              id: headerTitle
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: root.titleText()
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Row {
              anchors.right: parent.right
              anchors.rightMargin: 0
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              visible: viewMode === "list"

              PanelActionButton {
                iconText: "󰑐"
                tooltipText: root.fetching ? "Refreshing…" : "Refresh all"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: !root.fetching
                opacity: enabled ? 1 : 0.4
                onClicked: root.refreshAll(true)
              }
              PanelActionButton {
                iconText: "󰐕" // plus
                tooltipText: "Add parcel"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: { root.resetAdd(); viewMode = "add" }
              }
              PanelActionButton {
                iconText: "󰒓" // cog
                tooltipText: "Settings"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: viewMode = "settings"
              }
            }
          }

          // ==================== LIST VIEW ====================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: viewMode === "list"

            Text {
              width: parent.width
              visible: root.pkgList.length === 0
              textFormat: Text.PlainText
              text: "No parcels yet.\nAdd a tracking number to start tracking."
              color: Qt.darker(root.contentForeground, 1.6)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              topPadding: Style.space(20)
              bottomPadding: Style.space(10)
            }

            Button {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: root.pkgList.length === 0
              text: "Add parcel"
              foreground: root.contentForeground
              accent: Color.accent
              onClicked: { root.resetAdd(); viewMode = "add" }
            }

            // Active packages
            Repeater {
              model: root.sortedActive
              delegate: PackageRow { }
            }

            // Finished section
            PanelSectionHeader {
              width: parent.width
              visible: root.sortedFinished.length > 0
              text: "COMPLETED"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }
            Repeater {
              model: root.sortedFinished
              delegate: PackageRow { }
            }

            Text {
              width: parent.width
              visible: root.pkgList.length > 0 && !(prefs.aggregatorEnabled && (prefs.aggregatorKey || "").length > 0)
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "Automatic updates are off. Enable them in settings (opt-in aggregator), or use the refresh/open buttons per parcel."
              color: Qt.darker(root.contentForeground, 1.8)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              topPadding: Style.space(4)
            }
          }

          // ==================== DETAIL VIEW ====================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: viewMode === "detail"

            DetailContents { }
          }

          // ==================== ADD FLOW ====================
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: viewMode === "add"

            AddFlowContents { }
          }

          // ==================== SETTINGS ====================
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: viewMode === "settings"

            Toggle {
              width: parent.width
              label: "Desktop notifications"
              description: "Out for delivery, delivered, exceptions"
              checked: root.prefs.notify === true
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: root.setPrefs({ notify: !(root.prefs.notify === true) })
            }

            Rectangle { width: parent.width; height: Style.spacing.hairline; color: root.contentForeground; opacity: 0.1 }

            Toggle {
              width: parent.width
              label: "Automatic updates (17track)"
              description: "Opt-in aggregator. 17track sees every tracked number. Free API key required."
              checked: root.prefs.aggregatorEnabled === true
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: root.setPrefs({ aggregatorEnabled: !(root.prefs.aggregatorEnabled === true) })
            }

            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.prefs.aggregatorEnabled === true

              Text {
                textFormat: Text.PlainText
                text: "API key"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              TextField {
                id: apiKeyField
                width: parent.width
                password: true
                placeholderText: "Paste your 17track API key"
                foreground: root.contentForeground
                accent: Color.accent
                font.family: root.contentFontFamily
                text: root.prefs.aggregatorKey || ""
                onEditingFinished: root.setPrefs({ aggregatorKey: text.trim() })
              }

              Text {
                width: parent.width
                textFormat: Text.RichText
                wrapMode: Text.WordWrap
                text: "Get a free key at <a href='https://api.17track.net'>api.17track.net</a>. New accounts include a free tracking quota."
                color: Qt.darker(root.contentForeground, 1.8)
                linkColor: Color.accent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                onLinkActivated: function(link) { Qt.openUrlExternally(link) }
              }
            }

            Rectangle { width: parent.width; height: Style.spacing.hairline; color: root.contentForeground; opacity: 0.1 }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "Privacy: with automatic updates off, nothing leaves this machine. Deep links open the carrier's own site. Delivered parcels are archived after " + (root.prefs.archiveDays | 0) + " days."
              color: Qt.darker(root.contentForeground, 1.8)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  // ==================== Inline components ====================

  component PackageRow: Item {
    id: rowRoot
    required property var modelData
    readonly property var pkg: modelData

    width: parent ? parent.width : 0
    height: Math.max(rowContent.implicitHeight, Style.space(34))

    readonly property bool isCurrent: root.fetching && root.currentId === pkg.id

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: rowMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent"
    }

    Text {
      id: statusGlyph
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.statusGlyphs[rowRoot.pkg.status] || root.statusGlyphs.Unknown
      color: rowRoot.pkg.status === "Delivered"
        ? Color.accent
        : (rowRoot.pkg.status === "Exception" || rowRoot.pkg.status === "Returned" || rowRoot.pkg.status === "Expired")
          ? (root.bar ? root.bar.urgent : Color.urgent)
          : root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.title
    }

    PanelActionButton {
      id: refreshButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      iconText: "󰑐"
      visible: root.fetchAvailable(rowRoot.pkg)
      enabled: visible && !rowRoot.isCurrent
        && Model.canRefreshNow(rowRoot.pkg.lastAttemptAt | 0, root.effectiveInterval(rowRoot.pkg), root.nowPulse)
      tooltipText: enabled
        ? "Refresh now"
        : "Limited — again " + Model.relativeTime((rowRoot.pkg.lastAttemptAt | 0) + root.effectiveInterval(rowRoot.pkg), root.nowPulse)
      foreground: root.contentForeground
      fontFamily: root.contentFontFamily
      opacity: enabled ? 1 : 0.35
      onClicked: root.refreshPackage(rowRoot.pkg.id)
    }

    PanelActionButton {
      id: openButton
      anchors.right: refreshButton.visible ? refreshButton.left : parent.right
      anchors.rightMargin: refreshButton.visible ? Style.space(2) : 0
      anchors.verticalCenter: parent.verticalCenter
      iconText: "󰏌" // open-in-new
      tooltipText: "Open at " + Registry.providerName(rowRoot.pkg.provider)
      foreground: root.contentForeground
      fontFamily: root.contentFontFamily
      onClicked: root.openTracking(rowRoot.pkg)
    }

    Text {
      id: relativeLabel
      anchors.right: openButton.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: rowRoot.pkg.lastEventAt > 0 ? Model.relativeTime(rowRoot.pkg.lastEventAt, root.nowPulse) : ""
      color: Qt.darker(root.contentForeground, 1.8)
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }

    Column {
      id: rowContent
      anchors.left: statusGlyph.right
      anchors.leftMargin: Style.space(8)
      anchors.right: relativeLabel.visible && relativeLabel.text !== "" ? relativeLabel.left : openButton.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: (rowRoot.pkg.description || rowRoot.pkg.number) + "  ·  " + Registry.providerName(rowRoot.pkg.provider)
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideMiddle
        text: rowRoot.isCurrent
          ? "Refreshing…"
          : ((rowRoot.pkg.lastError || "") !== "" ? rowRoot.pkg.lastError : (rowRoot.pkg.statusLabel || Model.STATUS_LABELS[rowRoot.pkg.status] || ""))
        color: (rowRoot.pkg.lastError || "") !== ""
          ? (root.bar ? root.bar.urgent : Color.urgent)
          : Qt.darker(root.contentForeground, 1.6)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        root.selectedId = rowRoot.pkg.id
        root.editingDescription = false
        root.confirmingDelete = false
        root.viewMode = "detail"
      }
    }
  }

  component RouteStrip: Column {
    id: routeRoot
    width: parent.width
    spacing: Style.space(4)
    visible: !!routeRoot.pkg && routeRoot.stops.length >= 2

    property var pkg: null
    readonly property var stops: Model.routeStops(routeRoot.pkg ? routeRoot.pkg.events : [])

    Row {
      width: parent.width
      height: routeLabel.implicitHeight

      Text {
        id: routeLabel
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "Route"
        color: Qt.darker(root.contentForeground, 1.6)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Item { width: parent.width - routeLabel.implicitWidth - routeButton.width; height: parent.height }

      PanelActionButton {
        id: routeButton
        iconText: "󰴠" // map-marker-path
        tooltipText: "Show route in browser"
        foreground: root.contentForeground
        fontFamily: root.contentFontFamily
        onClicked: root.openRoute(routeRoot.pkg)
      }
    }

    Flow {
      width: parent.width
      spacing: Style.space(4)

        Repeater {
          id: routeRepeater
          model: {
            var s = routeRoot.stops
            var items = []
            if (s.length > 4)
              items = [{ text: s[0] }, { dots: s.length - 2 }, { text: s[s.length - 1] }]
            else
              for (var i = 0; i < s.length; i++) items.push({ text: s[i] })
            return items
          }

        delegate: Row {
          required property int index
          required property var modelData
          spacing: Style.space(4)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: modelData.dots
              ? "󰇘 " + modelData.dots + (modelData.dots === 1 ? " stop" : " stops")
              : modelData.text
            color: modelData.dots ? Qt.darker(root.contentForeground, 2.2) : Qt.darker(root.contentForeground, 1.6)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: index < routeRepeater.count - 1
            textFormat: Text.PlainText
            text: "󰅂"
            color: Qt.darker(root.contentForeground, 2.2)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
}

  component DetailContents: Column {
    id: detailRoot
    width: parent.width
    spacing: Style.space(8)

    // The panel instantiates this column even while hidden, so bindings
    // run before any package is selected. The stub keeps every binding
    // null-safe; visibility flags hide the actual content.
    readonly property var pkg: root.selectedPackage() || ({
      id: "", number: "", provider: "other", description: "",
      status: "Unknown", statusLabel: "", lastEvent: "", lastEventAt: 0,
      lastCheckedAt: 0, lastAttemptAt: 0, lastError: "",
      consecutiveFailures: 0, nextCheckAt: 0, events: []
    })
    readonly property bool hasPkg: root.selectedPackage() !== null
    readonly property color urgentColor: root.bar ? root.bar.urgent : Color.urgent

    Text {
      visible: detailRoot.hasPkg
      width: parent.width
      textFormat: Text.PlainText
      text: detailRoot.pkg.number
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.title
      font.bold: true
    }

    Row {
      visible: detailRoot.hasPkg
      width: parent.width
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: root.statusGlyphs[detailRoot.pkg.status] || root.statusGlyphs.Unknown
        color: detailRoot.pkg.status === "Delivered"
          ? Color.accent
          : (detailRoot.pkg.status === "Exception" || detailRoot.pkg.status === "Returned" || detailRoot.pkg.status === "Expired")
            ? detailRoot.urgentColor
            : root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.title
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Text {
          textFormat: Text.PlainText
          text: Model.STATUS_LABELS[detailRoot.pkg.status] || detailRoot.pkg.status
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {
          width: detailRoot.width
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: (detailRoot.pkg.statusLabel || "") + (detailRoot.pkg.lastError !== "" ? "  ·  " + detailRoot.pkg.lastError : "")
          color: detailRoot.pkg.lastError !== "" ? detailRoot.urgentColor : Qt.darker(root.contentForeground, 1.6)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // Description (click to edit)
    Loader {
      width: parent.width
      height: item ? item.height : 0
      active: detailRoot.hasPkg
      sourceComponent: root.editingDescription ? editDesc : viewDesc
    }

    Component {
      id: viewDesc
      Item {
        width: detailRoot.width
        height: descText.implicitHeight

        Text {
          id: descText
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: detailRoot.pkg.description !== "" ? detailRoot.pkg.description : "Add a description…"
          color: detailRoot.pkg.description !== "" ? root.contentForeground : Qt.darker(root.contentForeground, 2)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.italic: detailRoot.pkg.description === ""
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.editingDescription = true
        }
      }
    }

    Component {
      id: editDesc
      Item {
        width: detailRoot.width
        height: descField.height

        TextField {
          id: descField
          width: parent.width
          placeholderText: "e.g. Running shoes"
          foreground: root.contentForeground
          accent: Color.accent
          font.family: root.contentFontFamily
          text: detailRoot.pkg.description
          onEditingFinished: {
            root.setDescription(detailRoot.pkg.id, text)
            root.editingDescription = false
          }
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.setDescription(detailRoot.pkg.id, text)
              root.editingDescription = false
              event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
              root.editingDescription = false
              event.accepted = true
            }
          }
          Component.onCompleted: { forceActiveFocus(); selectAll() }
        }
      }
    }

    // Actions row: refresh, open, delete
    Row {
      visible: detailRoot.hasPkg
      spacing: Style.space(8)

      PanelActionButton {
        visible: root.fetchAvailable(detailRoot.pkg)
        enabled: visible && !root.fetching
          && Model.canRefreshNow(detailRoot.pkg.lastAttemptAt | 0, root.effectiveInterval(detailRoot.pkg), root.nowPulse)
        iconText: "󰑐"
        tooltipText: enabled
          ? "Refresh now"
          : "Limited — again " + Model.relativeTime((detailRoot.pkg.lastAttemptAt | 0) + root.effectiveInterval(detailRoot.pkg), root.nowPulse)
        foreground: root.contentForeground
        fontFamily: root.contentFontFamily
        opacity: enabled ? 1 : 0.35
        onClicked: root.refreshPackage(detailRoot.pkg.id)
      }

      PanelActionButton {
        iconText: "󰏌" // open-in-new
        tooltipText: "Open at " + Registry.providerName(detailRoot.pkg.provider)
        foreground: root.contentForeground
        fontFamily: root.contentFontFamily
        onClicked: root.openTracking(detailRoot.pkg)
      }

      PanelActionButton {
        iconText: "󰆴" // delete
        tooltipText: root.confirmingDelete ? "Click again to confirm" : "Remove package"
        foreground: root.confirmingDelete ? detailRoot.urgentColor : root.contentForeground
        fontFamily: root.contentFontFamily
        onClicked: {
          if (root.confirmingDelete) {
            root.removePackage(detailRoot.pkg.id)
            root.viewMode = "list"
            root.selectedId = ""
            root.confirmingDelete = false
          } else {
            root.confirmingDelete = true
            deleteReset.restart()
          }
        }
      }

      Timer {
        id: deleteReset
        interval: 3000
        onTriggered: root.confirmingDelete = false
      }
    }

    Rectangle { width: parent.width; height: Style.spacing.hairline; color: root.contentForeground; opacity: 0.1 }

    RouteStrip { pkg: detailRoot.pkg }

    // Timeline
    Column {
      visible: detailRoot.hasPkg && detailRoot.pkg.events.length > 0
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: detailRoot.hasPkg ? Math.min(detailRoot.pkg.events.length, 30) : 0
        delegate: Item {
          required property int index
          readonly property var ev: detailRoot.pkg.events[index]
          width: detailRoot.width
          height: Math.max(evLabel.implicitHeight, Style.space(20))

          Rectangle {
            id: dot
            x: Style.space(4)
            y: Style.space(6)
            width: Style.space(6)
            height: width
            radius: width / 2
            color: index === 0 ? Color.accent : Qt.darker(root.contentForeground, 1.5)
          }

          Column {
            anchors.left: dot.right
            anchors.leftMargin: Style.space(8)
            anchors.right: parent.right
            spacing: 0

            Text {
              id: evLabel
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: ev.label
              color: index === 0 ? root.contentForeground : Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: index === 0
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: (ev.loc !== "" ? ev.loc + "  ·  " : "") + (ev.t > 0 ? Qt.formatDateTime(new Date(ev.t * 1000), "MMM d, HH:mm") : "")
              color: Qt.darker(root.contentForeground, 2)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }

    Text {
      visible: detailRoot.hasPkg && detailRoot.pkg.events.length === 0
      width: parent.width
      textFormat: Text.PlainText
      text: root.fetchAvailable(detailRoot.pkg)
        ? "No tracking events yet — first refresh should populate this."
        : (Registry.providerById(detailRoot.pkg.provider) || { note: "" }).note
      color: Qt.darker(root.contentForeground, 1.8)
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  component AddFlowContents: Column {
    id: addRoot
    width: parent.width
    spacing: Style.space(10)

    // ---- Step 1: number
    Column {
      width: parent.width
      spacing: Style.space(6)
      visible: root.addStep === "number"

      Text {
        textFormat: Text.PlainText
        text: "Tracking number"
        color: Qt.darker(root.contentForeground, 1.5)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      TextField {
        id: numberField
        width: parent.width
        placeholderText: "1Z999AA10123456784"
        foreground: root.contentForeground
        accent: Color.accent
        font.family: root.contentFontFamily
        text: root.addNumber
        onTextChanged: {
          root.addNumber = text
          var suggestions = Registry.detect(text)
          root.addSuggestions = suggestions.slice(0, 4)
          root.addSelected = 0
          root.addProvider = suggestions.length > 0 ? suggestions[0].providerId : "other"
        }
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (Model.normalizeNumber(root.addNumber) !== "") root.addStep = "provider"
            event.accepted = true
          }
        }
        Component.onCompleted: forceActiveFocus()
      }

      // Live suggestions
      Column {
        width: parent.width
        spacing: Style.space(2)
        visible: root.addSuggestions.length > 0

        Text {
          textFormat: Text.PlainText
          text: "Likely carriers"
          color: Qt.darker(root.contentForeground, 1.8)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          topPadding: Style.space(4)
        }

        Repeater {
          model: root.addSuggestions
          delegate: SuggestionRow {
            selected: index === root.addSelected
            onClicked: {
              root.addSelected = index
              root.addProvider = suggestion.providerId
              root.addStep = "provider"
            }
          }
        }
      }

      Text {
        width: parent.width
        visible: Model.normalizeNumber(root.addNumber) !== "" && root.addSuggestions.length === 0
        textFormat: Text.PlainText
        text: "Format not recognized — you can pick a provider on the next step."
        color: Qt.darker(root.contentForeground, 1.8)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      ActionTextButton {
        width: parent.width
        label: "Continue"
        enabled: Model.normalizeNumber(root.addNumber) !== ""
        onClicked: if (enabled) root.addStep = "provider"
      }
    }

    // ---- Step 2: provider
    Column {
      width: parent.width
      spacing: Style.space(6)
      visible: root.addStep === "provider"

      Text {
        textFormat: Text.PlainText
        text: "Shipping provider"
        color: Qt.darker(root.contentForeground, 1.5)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Repeater {
        model: root.addSuggestions
        delegate: SuggestionRow {
          selected: root.addProvider === suggestion.providerId
          onClicked: root.addProvider = suggestion.providerId
        }
      }

      Rectangle { width: parent.width; height: Style.spacing.hairline; color: root.contentForeground; opacity: 0.1 }

      Repeater {
        model: allProviderOptions
        delegate: ProviderOptionRow {
          selected: root.addProvider === option.providerId
          onClicked: root.addProvider = option.providerId
        }
      }

      ActionTextButton {
        width: parent.width
        label: "Continue"
        enabled: root.addProvider !== ""
        onClicked: if (enabled) root.addStep = "description"
      }
    }

    // ---- Step 3: description
    Column {
      width: parent.width
      spacing: Style.space(6)
      visible: root.addStep === "description"

      Text {
        textFormat: Text.PlainText
        text: "Description (optional)"
        color: Qt.darker(root.contentForeground, 1.5)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      TextField {
        id: descAddField
        width: parent.width
        placeholderText: "e.g. Running shoes"
        foreground: root.contentForeground
        accent: Color.accent
        font.family: root.contentFontFamily
        text: root.addDescription
        onTextChanged: root.addDescription = text
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.addPackage()
            event.accepted = true
          }
        }
        Component.onCompleted: forceActiveFocus()
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: Model.normalizeNumber(root.addNumber) + "  ·  " + Registry.providerName(root.addProvider)
        color: Qt.darker(root.contentForeground, 1.6)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }

      ActionTextButton {
        width: parent.width
        label: "Add package"
        onClicked: root.addPackage()
      }
    }
  }

  // Full provider options for the override step (static entries; S10
  // operators are covered by suggestions and the "other" fallback).
  readonly property var allProviderOptions: {
    var list = []
    var providers = Registry.selectableProviders()
    for (var i = 0; i < providers.length; i++)
      if (!providers[i].aggregator) list.push(providers[i])
    return list
  }

  component SuggestionRow: Rectangle {
    id: suggRow
    required property var modelData
    required property int index
    readonly property var suggestion: modelData
    property bool selected: false
    signal clicked()

    width: parent ? parent.width : 0
    height: Style.space(30)
    radius: Style.cornerRadius
    color: suggMouse.containsMouse || selected
      ? Style.hoverFillFor(root.contentForeground, Color.accent)
      : "transparent"
    border.width: selected ? Style.spacing.hairline : 0
    border.color: Style.normalBorderFor(root.contentForeground, Color.accent)

    Row {
      anchors.fill: parent
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: suggestion.name
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
      }

      Item { anchors.verticalCenter: parent.verticalCenter; width: 1; height: 1 }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: Math.round(suggestion.confidence * 100) + "%"
        color: Qt.darker(root.contentForeground, 1.8)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: selected
        textFormat: Text.PlainText
        text: "󰗠"
        color: Color.accent
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
      }
    }

    MouseArea {
      id: suggMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: suggRow.clicked()
    }
  }

  component ProviderOptionRow: Rectangle {
    id: optRow
    required property var modelData
    readonly property var option: modelData
    property bool selected: false
    signal clicked()

    width: parent ? parent.width : 0
    height: Style.space(28)
    radius: Style.cornerRadius
    color: optMouse.containsMouse || selected
      ? Style.hoverFillFor(root.contentForeground, Color.accent)
      : "transparent"
    border.width: selected ? Style.spacing.hairline : 0
    border.color: Style.normalBorderFor(root.contentForeground, Color.accent)

    Row {
      anchors.fill: parent
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: option.name
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: selected
        textFormat: Text.PlainText
        text: "󰗠"
        color: Color.accent
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
      }
    }

    MouseArea {
      id: optMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: optRow.clicked()
    }
  }

  component ActionTextButton: Rectangle {
    id: actionBtn
    property string label: ""
    signal clicked()

    height: Style.space(30)
    radius: Style.cornerRadius
    color: actionMouse.containsMouse
      ? Style.hoverFillFor(root.contentForeground, Color.accent)
      : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.06)
    border.width: enabled ? Style.spacing.hairline : 0
    border.color: Style.normalBorderFor(root.contentForeground, Color.accent)
    opacity: enabled ? 1 : 0.4

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: actionBtn.label
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }

    MouseArea {
      id: actionMouse
      anchors.fill: parent
      hoverEnabled: enabled
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: actionBtn.clicked()
    }
  }
}
