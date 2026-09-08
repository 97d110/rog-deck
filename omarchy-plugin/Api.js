.pragma library

// The rog-deck service already owns every privileged path: it reads sysfs and
// delegates writes to asusd. The widget is a front-end over that HTTP API
// rather than a second implementation of the hardware logic.
var BASE = "http://127.0.0.1:8737"

function request(method, path, body, onDone) {
  var xhr = new XMLHttpRequest()
  xhr.onreadystatechange = function () {
    if (xhr.readyState !== XMLHttpRequest.DONE) return
    if (xhr.status === 0) {
      onDone(null, "rog-deck service is not running")
      return
    }
    var payload = null
    try {
      payload = JSON.parse(xhr.responseText)
    } catch (e) {
      onDone(null, "bad response from rog-deck")
      return
    }
    if (payload && payload.ok) onDone(payload.data, null)
    else onDone(null, (payload && payload.error) || ("HTTP " + xhr.status))
  }
  xhr.open(method, BASE + path)
  if (body) xhr.setRequestHeader("Content-Type", "application/json")
  xhr.send(body ? JSON.stringify(body) : null)
}

function get(path, onDone) { request("GET", path, null, onDone) }
function post(path, body, onDone) { request("POST", path, body, onDone) }

function warmestCpu(snapshot) {
  if (!snapshot || !snapshot.temperatures) return null
  for (var i = 0; i < snapshot.temperatures.length; i++) {
    var t = snapshot.temperatures[i]
    if (String(t.label).indexOf("Tctl") !== -1) return t
  }
  return null
}

// Shared by the bar label and the panel so a value is coloured the same in
// both places.
function level(value, range) {
  if (value === null || value === undefined || !range) return "ok"
  if (value >= range.crit) return "bad"
  if (value >= range.warn) return "warn"
  return "ok"
}
