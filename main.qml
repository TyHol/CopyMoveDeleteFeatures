import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore
import Theme
import org.qfield
import org.qgis

Item {
    property var mainWindow: iface.mainWindow()

    // Current operation mode
    property string _mode:      "delete"   // "delete" | "move" | "copy"
    property bool   _useFilter: false      // true = apply expression; false = act on all features

    // Cached field type for the currently selected filter field
    property string _currentFieldType: "text"

    // Feature count set by Execute before opening the confirm dialog
    property int    _pendingCount: 0

    // FeatureModel used to write features into the destination layer (move/copy)
    FeatureModel {
        id: moveFeatureModel
        project: qgisProject
    }

    // ── Persistent memory ─────────────────────────────────────────────────────
    Settings {
        id: filterMemory
        category: "CopyMoveDeleteFeatures"
        property string layerFilters:      "{}"
        property string lastLayerName:     ""
        property string lastDestLayerName: ""
        property string lastModeName:      ""
    }

    Component.onCompleted: {
        iface.addItemToPluginsToolbar(openButton)
    }

    Timer {
        id: suggestionTimer
        interval: 600
        repeat: false
        onTriggered: fetchSuggestions()
    }

    QfToolButton {
        id: openButton
        iconSource: 'icon.svg'
        iconColor: Theme.mainColor
        bgcolor: Theme.darkGray
        round: true
        onClicked: { updateLayers(); mainDialog.open() }
    }

    // ── Main dialog ───────────────────────────────────────────────────────────
    Dialog {
        id: mainDialog
        parent: mainWindow.contentItem
        modal: true
        title: _mode === "move"
               ? qsTr("Move features")
               : _mode === "copy" ? qsTr("Copy features")
               : qsTr("Delete features")
        standardButtons: Dialog.NoButton
        font: Theme.defaultFont
        width:  Math.min(mainWindow.width * 0.9, 420)
        height: Math.min(mainWindow.height - 40, 560)
        anchors.centerIn: parent

        // Custom header: title on the left, Help button on the right
        header: Item {
            implicitHeight: headerRow.implicitHeight + 20
            RowLayout {
                id: headerRow
                anchors {
                    left:            parent.left;  leftMargin:  16
                    right:           parent.right; rightMargin: 4
                    verticalCenter:  parent.verticalCenter
                }
                spacing: 0
                Label {
                    text: mainDialog.title
                    font.family:    Theme.defaultFont.family
                    font.pointSize: Theme.defaultFont.pointSize
                    font.bold:      true
                    color: Theme.mainTextColor
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                Button {
                    text: qsTr("Help")
                    font: Theme.tipFont
                    flat: true
                    onClicked: helpDialog.open()
                }
            }
        }

        // onAccepted is unused — Execute button calls tryExecute() directly
        // so the main dialog stays open while the confirm dialog is shown.
        onOpened: {
            var m = filterMemory.lastModeName
            if      (m === "copy")  _mode = "copy"
            else if (m === "move")  _mode = "move"
            else                    _mode = "delete"
        }
        onClosed: {
            suggestionPopup.close()
            filterMemory.lastLayerName     = layerSelector.currentText
            filterMemory.lastDestLayerName = destLayerSelector.currentText
            filterMemory.lastModeName      = _mode
        }

        // Outer ColumnLayout: scrollable content + pinned Execute/Cancel bar
        ColumnLayout {
            anchors.fill: parent
            spacing: 0

        ScrollView {
            id: mainScrollView
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ScrollBar.vertical.policy:   ScrollBar.AsNeeded

            ColumnLayout {
                width: mainScrollView.width
                       - (mainScrollView.ScrollBar.vertical.visible
                          ? mainScrollView.ScrollBar.vertical.width : 0)
                spacing: 6

                // ── Mode buttons ──────────────────────────────────────────────
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Button {
                        text: qsTr("Delete"); Layout.fillWidth: true
                        highlighted: _mode === "delete"; font: Theme.tipFont
                        onClicked: _mode = "delete"
                    }
                    Button {
                        text: qsTr("Move"); Layout.fillWidth: true
                        highlighted: _mode === "move"; font: Theme.tipFont
                        onClicked: _mode = "move"
                    }
                    Button {
                        text: qsTr("Copy"); Layout.fillWidth: true
                        highlighted: _mode === "copy"; font: Theme.tipFont
                        onClicked: _mode = "copy"
                    }
                }

                // ── All / Filter toggle (green-tinted, visually distinct) ─────
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Button {
                        id: allBtn
                        text: qsTr("All"); Layout.fillWidth: true; font: Theme.tipFont
                        // 'highlighted' is FINAL on Button — use a custom property name
                        readonly property bool isActive: !_useFilter
                        background: Rectangle {
                            radius: 4
                            color:        allBtn.isActive ? Theme.mainColor
                                          : Qt.rgba(Theme.mainColor.r, Theme.mainColor.g, Theme.mainColor.b, 0.12)
                            border.color: Theme.mainColor; border.width: 1
                        }
                        contentItem: Text {
                            text: allBtn.text; font: allBtn.font
                            color: allBtn.isActive ? "white" : Theme.mainColor
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment:   Text.AlignVCenter
                            elide: Text.ElideRight
                        }
                        onClicked: { _useFilter = false }
                    }
                    Button {
                        id: filterBtn
                        text: qsTr("Filter"); Layout.fillWidth: true; font: Theme.tipFont
                        readonly property bool isActive: _useFilter
                        background: Rectangle {
                            radius: 4
                            color:        filterBtn.isActive ? Theme.mainColor
                                          : Qt.rgba(Theme.mainColor.r, Theme.mainColor.g, Theme.mainColor.b, 0.12)
                            border.color: Theme.mainColor; border.width: 1
                        }
                        contentItem: Text {
                            text: filterBtn.text; font: filterBtn.font
                            color: filterBtn.isActive ? "white" : Theme.mainColor
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment:   Text.AlignVCenter
                            elide: Text.ElideRight
                        }
                        onClicked: { _useFilter = true }
                    }
                }

                // ── Source layer ──────────────────────────────────────────────
                Label { text: qsTr("Source layer"); font: Theme.tipFont; color: Theme.mainTextColor }
                ComboBox {
                    id: layerSelector
                    Layout.fillWidth: true; model: []; font: Theme.tipFont
                    onCurrentTextChanged: {
                        updateFieldSelector()
                        updateDestLayerSelector()
                        restoreLayerFilter(currentText)
                    }
                }

                // ── Destination layer (move / copy only) ──────────────────────
                Label {
                    text: qsTr("Destination layer"); font: Theme.tipFont; color: Theme.mainTextColor
                    visible: _mode === "move" || _mode === "copy"
                }
                ComboBox {
                    id: destLayerSelector
                    Layout.fillWidth: true; model: []; font: Theme.tipFont
                    visible: _mode === "move" || _mode === "copy"
                    onCurrentTextChanged: updateFieldMapLabel()
                }
                Label {
                    id: fieldMapLabel
                    Layout.fillWidth: true; text: ""; wrapMode: Text.Wrap
                    font: Theme.tipFont; color: Theme.secondaryTextColor
                    visible: (_mode === "move" || _mode === "copy") && text !== ""
                }

                // ── Filter section (visible when Filter is selected) ───────────
                ColumnLayout {
                    visible: _useFilter
                    Layout.fillWidth: true
                    spacing: 6

                    // Filter section label
                    //Label { text: qsTr("Filter"); font: Theme.tipFont; color: Theme.mainTextColor }

                    // Field + Operator
                    RowLayout {
                        Layout.fillWidth: true; spacing: 4
                        ComboBox {
                            id: fieldSelector
                            Layout.fillWidth: true; model: []; font: Theme.tipFont
                            displayText: currentText || qsTr("Field…")
                            onCurrentTextChanged: {
                                valueField.text = ""
                                suggestionPopup.close()
                                var lyr = getLayerByName(layerSelector.currentText)
                                _currentFieldType = lyr ? detectFieldType(lyr, currentText) : "text"
                            }
                        }
                        ComboBox {
                            id: operatorSelector
                            Layout.preferredWidth: 80; font: Theme.tipFont
                            model: ["=", "<>", ">", "<", ">=", "<=", "LIKE", "IN", "NOT IN", "IS NULL", "IS NOT NULL"]
                            onCurrentTextChanged: {
                                suggestionPopup.close()
                                if (currentText !== "IS NULL" && currentText !== "IS NOT NULL"
                                        && valueField.text.trim() === "")
                                    suggestionTimer.restart()
                            }
                        }
                    }

                    // Value field
                    Item {
                        Layout.fillWidth: true
                        implicitHeight: valueField.implicitHeight
                        visible: operatorSelector.currentText !== "IS NULL"
                               && operatorSelector.currentText !== "IS NOT NULL"

                        TextField {
                            id: valueField
                            anchors.fill: parent; font: Theme.tipFont
                            placeholderText: {
                                var op = operatorSelector.currentText
                                if (op === "IN" || op === "NOT IN")      return qsTr("val1, val2, val3…")
                                if (_currentFieldType === "datetime")     return qsTr("YYYY-MM-DD HH:MM:SS  or  now()")
                                if (_currentFieldType === "date")         return qsTr("YYYY-MM-DD  or  today()")
                                return qsTr("Value  or  now(), today()…")
                            }
                            onTextEdited: {
                                if (/^\w+\s*\(/.test(text)) { suggestionPopup.close(); return }
                                suggestionTimer.restart()
                            }
                            onActiveFocusChanged: {
                                if (activeFocus && !/^\w+\s*\(/.test(text)) suggestionTimer.restart()
                                else suggestionPopup.close()
                            }
                        }

                        Popup {
                            id: suggestionPopup
                            y: valueField.height + 2; x: 0
                            width: valueField.width
                            height: Math.min(suggestionList.contentHeight + 8, 180)
                            padding: 4
                            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                            background: Rectangle {
                                color: Theme.mainBackgroundColor
                                border.color: Theme.mainColor; border.width: 1; radius: 4
                            }
                            ListView {
                                id: suggestionList
                                anchors.fill: parent; clip: true; model: []
                                delegate: ItemDelegate {
                                    width: suggestionList.width; text: modelData
                                    font: Theme.tipFont; highlighted: hovered
                                    onClicked: {
                                        var op = operatorSelector.currentText
                                        if (op === "IN" || op === "NOT IN") {
                                            var cur = valueField.text.trim()
                                            valueField.text = cur === "" ? modelData : cur + ", " + modelData
                                        } else {
                                            valueField.text = modelData
                                        }
                                        suggestionPopup.close()
                                        valueField.forceActiveFocus()
                                    }
                                }
                            }
                        }
                    }

                    // Apply / Clear buttons
                    RowLayout {
                        Layout.fillWidth: true; spacing: 4
                        Button {
                            text: qsTr("Apply Filter"); Layout.fillWidth: true; font: Theme.tipFont
                            enabled: fieldSelector.currentText !== ""
                                  && (valueField.text.trim() !== "" || !valueField.visible)
                            onClicked: {
                                suggestionPopup.close()
                                var expr = buildExpression()
                                if (expr) {
                                    exprField.text = expr
                                    saveLayerFilter(layerSelector.currentText)
                                }
                            }
                        }
                        Button {
                            text: qsTr("Clear"); Layout.fillWidth: true; font: Theme.tipFont
                            onClicked: {
                                valueField.text = ""
                                exprField.text  = ""
                                suggestionPopup.close()
                                clearLayerFilter(layerSelector.currentText)
                            }
                        }
                    }

                    // Editable expression field
                    Label { id: exprPreviewLabel; text: ""; visible: false }
                    Label { text: qsTr("Expression (editable):"); font: Theme.tipFont; color: Theme.secondaryTextColor }
                    TextField {
                        id: exprField
                        Layout.fillWidth: true
                        font.family: "monospace"; font.pointSize: Theme.tipFont.pointSize
                        placeholderText: qsTr("e.g. \"name\" = 'Tom'")
                        wrapMode: TextInput.Wrap
                    }

                    // Performance note
                    Label {
                        Layout.fillWidth: true
                        text: qsTr("⚠ Note: may be slow with large numbers of features.")
                        font: Theme.tipFont; color: Theme.secondaryTextColor
                        wrapMode: Text.Wrap; opacity: 0.8
                    }
                }   // end filter section

            }   // end inner ColumnLayout
        }   // end ScrollView

        // ── Pinned Execute / Cancel bar ───────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            Layout.topMargin: 4
            Layout.bottomMargin: 4
            Layout.leftMargin: 2
            Layout.rightMargin: 2

            Button {
                text: qsTr("Cancel")
                Layout.fillWidth: true
                font: Theme.defaultFont
                onClicked: mainDialog.close()
            }
            Button {
                text: qsTr("Execute")
                Layout.fillWidth: true
                highlighted: true
                font: Theme.defaultFont
                onClicked: tryExecute()   // keeps mainDialog open; confirm dialog opens on top
            }
        }

        }   // end outer ColumnLayout
    }   // end mainDialog

    // ── Confirm dialog — shows feature count, Proceed / Cancel ───────────────
    Dialog {
        id: confirmDialog
        parent: mainWindow.contentItem
        modal: true
        font: Theme.defaultFont
        standardButtons: Dialog.NoButton
        anchors.centerIn: parent
        width: Math.min(mainWindow.width * 0.9, 420)
        title: _mode === "move" ? qsTr("Confirm Move")
             : _mode === "copy" ? qsTr("Confirm Copy")
             : qsTr("Confirm Delete")

        ColumnLayout {
            width: parent.width
            spacing: 12

            // ── Feature count — large and prominent ───────────────────────────
            Label {
                Layout.fillWidth: true
                text: {
                    var n    = _pendingCount
                    var noun = n === 10001 ? qsTr("10,000+ features")
                             : n === 1     ? qsTr("1 feature")
                             : qsTr("%1 features").arg(n)
                    var verb = _mode === "move" ? qsTr("will be moved")
                             : _mode === "copy" ? qsTr("will be copied")
                             : qsTr("will be deleted")
                    var src  = qsTr(" from '%1'").arg(layerSelector.currentText)
                    var dest = (_mode === "move" || _mode === "copy")
                               ? qsTr("\n→  '%1'").arg(destLayerSelector.currentText) : ""
                    return noun + " " + verb + src + dest
                }
                font.pointSize: Theme.defaultFont.pointSize * 1.15
                font.bold: true
                color: _mode === "delete" ? "#c0392b"   // red for delete
                     : _mode === "move"   ? "#e67e22"   // amber for move
                     : "#2980b9"                        // blue for copy
                wrapMode: Text.Wrap
            }

            // ── Expression (shown only when a filter is active) ───────────────
            Label {
                Layout.fillWidth: true
                visible: _useFilter && exprField.text.trim() !== ""
                text: qsTr("Filter:  ") + exprField.text.trim()
                font.family: "monospace"
                font.pointSize: Theme.tipFont.pointSize
                color: Theme.secondaryTextColor
                wrapMode: Text.Wrap
            }

            // ── Proceed / Cancel ──────────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Button {
                    text: qsTr("Cancel"); Layout.fillWidth: true; font: Theme.defaultFont
                    onClicked: confirmDialog.reject()   // closes confirm only; main dialog stays open
                }
                Button {
                    text: qsTr("Proceed"); Layout.fillWidth: true
                    highlighted: true; font: Theme.defaultFont
                    onClicked: confirmDialog.accept()   // executes, then closes both dialogs
                }
            }
        }

        onAccepted: {
            var srcLayer = getLayerByName(layerSelector.currentText)
            if (!srcLayer) return

            if (_useFilter && fieldSelector.currentText && valueField.text.trim() !== "")
                saveLayerFilter(layerSelector.currentText)

            var expr = (_useFilter && exprField.text.trim() !== "") ? exprField.text.trim() : "1=1"

            if (_mode === "move" || _mode === "copy") {
                var dstLayer = getLayerByName(destLayerSelector.currentText)
                if (!dstLayer) return
                var count = directCopyMoveByExpression(srcLayer, dstLayer, expr, _mode === "move")
                if (count > 0) {
                    var verb = _mode === "move" ? qsTr("Moved") : qsTr("Copied")
                    mainWindow.displayToast(
                        qsTr("%1 %2 feature(s): '%3' → '%4'")
                            .arg(verb).arg(count).arg(srcLayer.name).arg(dstLayer.name))
                }
            } else {
                directDeleteByExpression(srcLayer, expr)
            }
            // Close the main dialog after successful execution
            mainDialog.close()
        }
    }

    // ── Functions ─────────────────────────────────────────────────────────────

    // ── Validate, count and open the confirm dialog ───────────────────────────
    // Called by the Execute button. Does NOT close mainDialog — it stays open
    // behind the confirm dialog so Cancel returns the user here.
    function tryExecute() {
        if (!layerSelector.currentText) {
            mainWindow.displayToast(qsTr("Choose a source layer."))
            return
        }
        if ((_mode === "move" || _mode === "copy") && !destLayerSelector.currentText) {
            mainWindow.displayToast(qsTr("No compatible destination layer — destination must be the same geometry type as the source."))
            return
        }
        if (_useFilter && exprField.text.trim() === "") {
            mainWindow.displayToast(qsTr("Enter a filter expression or switch to All."))
            return
        }
        var srcLayer = getLayerByName(layerSelector.currentText)
        if (!srcLayer) return
        var expr = (_useFilter && exprField.text.trim() !== "") ? exprField.text.trim() : "1=1"
        var n = countMatchingFeatures(srcLayer, expr)
        if (n === 0) {
            mainWindow.displayToast(qsTr("No features matched — nothing to do."))
            return
        }
        _pendingCount = n
        confirmDialog.open()
    }

    // Count features matching expr (or all features for "1=1").
    // Caps at 10 001 so we never hang on huge layers — returns 10001 to signal "10 000+".
    function countMatchingFeatures(layer, expr) {
        if (!layer) return 0
        // Fast path: entire layer with no filter
        if (expr === "1=1") {
            try {
                var fc = (typeof layer.featureCount === "function")
                         ? layer.featureCount() : layer.featureCount
                if (typeof fc === "number" && fc >= 0) return Math.min(fc, 10001)
            } catch(e) {}
        }
        // Filtered: iterate and count (cap at 10 001 to stay responsive)
        var count = 0
        try {
            var it = LayerUtils.createFeatureIteratorFromExpression(layer, expr)
            while (it.hasNext() && count < 10001) { it.next(); count++ }
        } catch(e) { return 0 }
        return count
    }

    function updateLayers() {
        var layers = ProjectUtils.mapLayers(qgisProject)
        var names = []
        for (var id in layers) { var l = layers[id]; if (l && l.supportsEditing) names.push(l.name) }
        names.sort()
        layerSelector.model = names
        var savedIdx = names.indexOf(filterMemory.lastLayerName)
        layerSelector.currentIndex = savedIdx >= 0 ? savedIdx : (names.length > 0 ? 0 : -1)
    }

    function getLayerByName(name) {
        var layers = ProjectUtils.mapLayers(qgisProject)
        for (var id in layers) if (layers[id] && layers[id].name === name) return layers[id]
        return null
    }

    function updateFieldSelector() {
        var layer = getLayerByName(layerSelector.currentText)
        if (!layer || !layer.fields) {
            fieldSelector.model = []
            _currentFieldType = "text"
            return
        }
        var names = []
        try { names = layer.fields.names ? layer.fields.names.slice() : [] } catch(e) {}
        names.sort()
        fieldSelector.model = names
        fieldSelector.currentIndex = names.length > 0 ? 0 : -1
        _currentFieldType = names.length > 0 ? detectFieldType(layer, names[0]) : "text"
    }

    // ── Filter memory ─────────────────────────────────────────────────────────

    function saveLayerFilter(layerName) {
        if (!layerName) return
        var filters = {}
        try { filters = JSON.parse(filterMemory.layerFilters) } catch(e) {}
        filters[layerName] = {
            field: fieldSelector.currentText,
            op:    operatorSelector.currentText,
            value: valueField.text
        }
        filterMemory.layerFilters = JSON.stringify(filters)
    }

    function clearLayerFilter(layerName) {
        if (!layerName) return
        var filters = {}
        try { filters = JSON.parse(filterMemory.layerFilters) } catch(e) {}
        delete filters[layerName]
        filterMemory.layerFilters = JSON.stringify(filters)
        exprPreviewLabel.text = ""
        exprField.text        = ""
    }

    // Restore saved filter for this layer and rebuild the expression field.
    // Switches to Filter mode automatically if a saved filter exists.
    function restoreLayerFilter(layerName) {
        var filters = {}
        try { filters = JSON.parse(filterMemory.layerFilters) } catch(e) {}
        var saved = filters[layerName]

        if (!saved || !saved.field) {
            _useFilter = false
            valueField.text = ""
            exprField.text  = ""
            return
        }

        _useFilter = true

        var fieldIdx = fieldSelector.model.indexOf(saved.field)
        fieldSelector.currentIndex = fieldIdx >= 0 ? fieldIdx : 0

        var ops = ["=", "<>", ">", "<", ">=", "<=", "LIKE", "IN", "NOT IN", "IS NULL", "IS NOT NULL"]
        var opIdx = ops.indexOf(saved.op)
        operatorSelector.currentIndex = opIdx >= 0 ? opIdx : 0

        valueField.text = saved.value || ""

        var expr = buildExpression()
        if (expr) {
            exprPreviewLabel.text = expr
            exprField.text        = expr
        }
    }

    // Populate destination selector with layers matching the source geometry type
    function updateDestLayerSelector() {
        var srcLayer = getLayerByName(layerSelector.currentText)
        if (!srcLayer) { destLayerSelector.model = []; return }
        var srcGt = srcLayer.geometryType ? srcLayer.geometryType() : -1

        var layers = ProjectUtils.mapLayers(qgisProject)
        var names = []
        for (var id in layers) {
            var l = layers[id]
            if (!l || !l.supportsEditing) continue
            if (l.name === layerSelector.currentText) continue
            var gt = l.geometryType ? l.geometryType() : -1
            if (gt === srcGt) names.push(l.name)
        }
        names.sort()
        destLayerSelector.model = names
        var savedDest = names.indexOf(filterMemory.lastDestLayerName)
        destLayerSelector.currentIndex = savedDest >= 0 ? savedDest : (names.length > 0 ? 0 : -1)
        // Warn clearly when no matching-geometry destination layers exist
        if (names.length === 0) {
            var gtName = srcGt === Qgis.GeometryType.Point   ? qsTr("point")
                       : srcGt === Qgis.GeometryType.Line    ? qsTr("line")
                       : srcGt === Qgis.GeometryType.Polygon ? qsTr("polygon")
                       : qsTr("same geometry type")
            fieldMapLabel.text = qsTr("⚠ No editable %1 layers found to copy/move into.").arg(gtName)
        }
        updateFieldMapLabel()
    }

    // Show which source fields will map to destination fields
    function updateFieldMapLabel() {
        if (_mode === "delete") { fieldMapLabel.text = ""; return }
        var srcLayer = getLayerByName(layerSelector.currentText)
        var dstLayer = getLayerByName(destLayerSelector.currentText)
        if (!srcLayer || !dstLayer) { fieldMapLabel.text = ""; return }

        var srcNames = []; var dstNames = []
        try { srcNames = srcLayer.fields.names || [] } catch(e) {}
        try { dstNames = dstLayer.fields.names || [] } catch(e) {}

        var mapped = [], unmapped = []
        for (var i = 0; i < srcNames.length; i++) {
            if (dstNames.indexOf(srcNames[i]) !== -1) mapped.push(srcNames[i])
            else unmapped.push(srcNames[i])
        }
        var parts = []
        if (mapped.length > 0)   parts.push(qsTr("✔ mapped: ") + mapped.join(", "))
        if (unmapped.length > 0) parts.push(qsTr("✘ dropped: ") + unmapped.join(", "))
        fieldMapLabel.text = parts.join("\n")
    }

    // ── Date/time field detection ─────────────────────────────────────────────
    function detectFieldType(layer, fieldName) {
        if (!layer || !fieldName) return "text"
        try {
            var fields = layer.fields
            if (!fields) return "text"
            try {
                var fld = fields.field(fieldName)
                if (fld) {
                    var tn = typeof fld.typeName === 'function' ? fld.typeName() : fld.typeName
                    if (tn) {
                        tn = String(tn).toLowerCase()
                        if (tn === "datetime" || tn === "timestamp") return "datetime"
                        if (tn === "date")   return "date"
                        if (tn === "time")   return "time"
                        if (tn.indexOf("int") !== -1 || tn === "double" ||
                            tn === "real" || tn === "float" || tn === "decimal") return "numeric"
                        return "text"
                    }
                }
            } catch(e) {}
            try {
                var fld2 = fields.field(fieldName)
                if (fld2 && fld2.type !== undefined) {
                    var t = fld2.type
                    if (t === 16) return "datetime"
                    if (t === 14) return "date"
                    if (t === 15) return "time"
                    if (t === 2 || t === 3 || t === 4 || t === 5 || t === 6) return "numeric"
                }
            } catch(e) {}
        } catch(e) {}
        try {
            var it = LayerUtils.createFeatureIteratorFromExpression(
                layer, '"' + fieldName + '" IS NOT NULL')
            if (it.hasNext()) {
                var rawVal = it.next().attribute(fieldName)
                if (rawVal instanceof Date)
                    return isNaN(rawVal.getTime()) ? "text" : "datetime"
                var sv = String(rawVal || "").trim()
                if (/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/.test(sv)) return "datetime"
                if (/^\d{4}-\d{2}-\d{2}$/.test(sv))                 return "date"
                if (sv.length > 10 && isNaN(parseFloat(sv))) {
                    try {
                        var pd = new Date(sv)
                        if (!isNaN(pd.getTime()) && pd.getFullYear() > 1900 && pd.getFullYear() < 2200)
                            return "datetime"
                    } catch(e) {}
                }
            }
        } catch(e) {}
        return "text"
    }

    function formatDateValue(val, fieldType) {
        if (val === null || val === undefined) return null
        var keepTime = (fieldType === "datetime")
        function fromDate(d) {
            if (isNaN(d.getTime())) return null
            var y  = d.getFullYear()
            var mo = String(d.getMonth() + 1).padStart(2, "0")
            var dy = String(d.getDate()).padStart(2, "0")
            if (!keepTime) return y + "-" + mo + "-" + dy
            var h  = String(d.getHours()).padStart(2, "0")
            var mi = String(d.getMinutes()).padStart(2, "0")
            var s  = String(d.getSeconds()).padStart(2, "0")
            return y + "-" + mo + "-" + dy + " " + h + ":" + mi + ":" + s
        }
        if (val instanceof Date) return fromDate(val)
        var s = String(val).trim()
        if (/^\d{4}-\d{2}-\d{2}/.test(s)) {
            if (!keepTime) return s.substring(0, 10)
            var norm = s.replace("T", " ")
            return /\d{2}:\d{2}/.test(norm) ? norm.substring(0, 19) : norm.substring(0, 10)
        }
        try {
            var d = new Date(s)
            if (!isNaN(d.getTime()) && d.getFullYear() > 1900 && d.getFullYear() < 2200)
                return fromDate(d)
        } catch(e) {}
        return s
    }

    function fetchSuggestions() {
        suggestionPopup.close()
        var op = operatorSelector.currentText
        if (op === "IS NULL" || op === "IS NOT NULL") return
        var layer = getLayerByName(layerSelector.currentText)
        if (!layer) return
        var field = fieldSelector.currentText
        if (!field) return
        var searchText = valueField.text.trim()
        if (/^\w+\s*\(/.test(searchText)) return

        var fieldType  = _currentFieldType
        var isDateType = fieldType === "date" || fieldType === "datetime" || fieldType === "time"
        var iterExpr
        if (searchText === "") {
            iterExpr = '"' + field + '" IS NOT NULL'
        } else if (isDateType) {
            iterExpr = 'to_string(date("' + field + '")) ILIKE \'%' + searchText.replace(/'/g, "''") + '%\''
        } else {
            iterExpr = 'to_string("' + field + '") ILIKE \'%' + searchText.replace(/'/g, "''") + '%\''
        }
        var seen = {}, values = []
        try {
            var it = LayerUtils.createFeatureIteratorFromExpression(layer, iterExpr)
            var scanned = 0
            while (it.hasNext() && values.length < 15 && scanned < 200) {
                var feat = it.next()
                var raw  = null
                try { raw = feat.attribute(field) } catch(e) {}
                if (raw !== null && raw !== undefined) {
                    var sv = isDateType ? formatDateValue(raw, fieldType) : String(raw).trim()
                    if (sv && sv !== "NULL" && !seen[sv]) { seen[sv] = true; values.push(sv) }
                }
                scanned++
            }
            values.sort()
        } catch(e) {}
        suggestionList.model = values
        if (values.length > 0) suggestionPopup.open()
    }

    function buildExpression() {
        var field = fieldSelector.currentText
        var op    = operatorSelector.currentText
        if (!field) return ""
        if (op === "IS NULL")     return '"' + field + '" IS NULL'
        if (op === "IS NOT NULL") return '"' + field + '" IS NOT NULL'

        var raw = valueField.text.trim()
        if (raw === "") return ""

        var isNumeric  = !isNaN(parseFloat(raw)) && isFinite(raw)
        var isFunction = /^\w+\s*\(/.test(raw)
        var fieldType  = _currentFieldType
        var isDateType = fieldType === "date" || fieldType === "datetime" || fieldType === "time"
        var expr

        if (op === "LIKE") {
            var v = raw.indexOf("%") === -1
                    ? "%" + raw.replace(/'/g, "''") + "%"
                    : raw.replace(/'/g, "''")
            expr = '"' + field + '" ILIKE \'' + v + '\''

        } else if (op === "IN" || op === "NOT IN") {
            var parts = raw.split(/\s*[,;]\s*/).map(function(p) { return p.trim() })
                           .filter(function(p) { return p !== "" })
            if (parts.length === 0) return ""
            var inVals = parts.map(function(p) {
                var pIsNum = !isNaN(parseFloat(p)) && isFinite(p)
                var pIsFn  = /^\w+\s*\(/.test(p)
                if (pIsNum || pIsFn) return p
                if (isDateType) {
                    var cp     = formatDateValue(p, fieldType) || p
                    var cpHasT = /\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/.test(cp)
                    var fn     = (fieldType === "datetime" && cpHasT) ? "to_datetime" : "to_date"
                    return fn + "('" + cp.replace(/'/g, "''") + "')"
                }
                return "'" + p.replace(/'/g, "''") + "'"
            })
            expr = '"' + field + '" ' + op + ' (' + inVals.join(", ") + ')'

        } else if (isFunction || isNumeric) {
            // today() with = on a datetime field: strip the time before comparing,
            // otherwise no features match (date != datetime with time component).
            // today() with < / > works fine as-is; now() is always passed through.
            if (isFunction && fieldType === "datetime" && op === "="
                    && /^today\s*\(/i.test(raw)) {
                expr = 'date("' + field + '") = today()'
            } else {
                expr = '"' + field + '" ' + op + ' ' + raw
            }

        } else if (isDateType) {
            var cleanDate = formatDateValue(raw, fieldType) || raw
            var hasTime   = /\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/.test(cleanDate)
            if (fieldType === "datetime" && hasTime && op === "=") {
                expr = "format_date(\"" + field + "\", 'yyyy-MM-dd HH:mm:ss') = '" +
                       cleanDate.replace(/'/g, "''") + "'"
            } else if (fieldType === "datetime" && hasTime) {
                expr = '"' + field + '" ' + op + ' ' + "to_datetime('" + cleanDate.replace(/'/g, "''") + "')"
            } else if (fieldType === "datetime" && op === "=") {
                expr = 'date("' + field + '") = ' + "to_date('" + cleanDate.replace(/'/g, "''") + "')"
            } else {
                expr = '"' + field + '" ' + op + ' ' + "to_date('" + cleanDate.replace(/'/g, "''") + "')"
            }
        } else {
            expr = '"' + field + '" ' + op + " '" + raw.replace(/'/g, "''") + "'"
        }

        exprField.text = expr
        return expr
    }

    // ── Execute: delete ALL features matching expr ────────────────────────────
    function directDeleteByExpression(layer, expr) {
        try {
            if (!layer.isEditable) layer.startEditing()
            layer.selectByExpression(expr)
            layer.triggerRepaint()
            var ok = layer.deleteSelectedFeatures()
            if (ok) {
                layer.commitChanges()
                layer.triggerRepaint()
                mainWindow.displayToast(
                    qsTr("Deleted all matching features from '%1'.").arg(layer.name))
                return true
            }
            layer.rollBack()
            mainWindow.displayToast(qsTr("Delete failed."))
            return false
        } catch(e) {
            try { layer.rollBack() } catch(e2) {}
            mainWindow.displayToast(qsTr("Error: %1").arg(e.toString()))
            return false
        }
    }

    // ── Execute: copy/move ALL features matching expr ─────────────────────────
    function directCopyMoveByExpression(srcLayer, dstLayer, expr, deleteSource) {
        var features = []
        try {
            var it = LayerUtils.createFeatureIteratorFromExpression(srcLayer, expr)
            while (it.hasNext()) features.push(it.next())
        } catch(e) {
            mainWindow.displayToast(qsTr("Could not read features: %1").arg(e.toString()))
            return -1
        }
        if (features.length === 0) {
            mainWindow.displayToast(qsTr("No features matched."))
            return 0
        }

        var dstFieldNames = []
        try { dstFieldNames = dstLayer.fields.names || [] } catch(e) {}
        var dstFieldIdx = {}
        for (var fi = 0; fi < dstFieldNames.length; fi++)
            dstFieldIdx[dstFieldNames[fi]] = fi

        var srcFieldNames = []
        try { srcFieldNames = srcLayer.fields.names || [] } catch(e) {}

        moveFeatureModel.currentLayer = dstLayer
        moveFeatureModel.batchMode = true
        var written = 0

        for (var i = 0; i < features.length; i++) {
            try {
                var srcFeat = features[i]
                var geom = srcFeat.geometry
                if (!geom) continue
                var newFeat = FeatureUtils.createBlankFeature(dstLayer.fields, geom)
                for (var si = 0; si < srcFieldNames.length; si++) {
                    var fname = srcFieldNames[si]
                    if (dstFieldIdx[fname] === undefined) continue
                    var attrVal = null
                    try { attrVal = srcFeat.attribute(fname) } catch(e) {}
                    if (attrVal !== null && attrVal !== undefined)
                        newFeat.setAttribute(dstFieldIdx[fname], attrVal)
                }
                moveFeatureModel.feature = newFeat
                if (moveFeatureModel.create()) written++
            } catch(e) {
                iface.logMessage("directCopyMove feature error: " + e)
            }
        }
        moveFeatureModel.batchMode = false

        if (written === 0) {
            mainWindow.displayToast(qsTr("No features could be written to destination."))
            return 0
        }

        if (!deleteSource) return written

        try {
            if (!srcLayer.isEditable) srcLayer.startEditing()
            srcLayer.selectByExpression(expr)
            srcLayer.triggerRepaint()
            var ok = srcLayer.deleteSelectedFeatures()
            if (ok) {
                srcLayer.commitChanges(); srcLayer.triggerRepaint()
                return written
            }
            srcLayer.rollBack()
            mainWindow.displayToast(
                qsTr("Copied %1 to destination but could not delete from source.").arg(written))
            return written
        } catch(e) {
            try { srcLayer.rollBack() } catch(e2) {}
            mainWindow.displayToast(qsTr("Source delete error: %1").arg(e.toString()))
            return written
        }
    }

    // ── Help dialog ───────────────────────────────────────────────────────────
    Dialog {
        id: helpDialog
        parent: mainWindow.contentItem
        modal: true
        title: qsTr("CopyMoveDeleteFeatures — Help")
        standardButtons: Dialog.Close
        anchors.centerIn: parent
        width:  Math.min(mainWindow.width * 0.95, 440)
        height: Math.min(mainWindow.height * 0.88, 640)
        font: Theme.defaultFont

        ScrollView {
            anchors.fill: parent; clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ScrollBar.vertical.policy:   ScrollBar.AsNeeded

            ColumnLayout {
                width: helpDialog.availableWidth
                spacing: 14

                Label {
                    text: qsTr("HOW TO USE")
                    font.bold: true; font.pointSize: Theme.defaultFont.pointSize
                    color: Theme.mainColor
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.Wrap
                    font: Theme.tipFont; color: Theme.mainTextColor
                    text: qsTr(
                        "1. Choose Delete, Move or Copy at the top.\n" +
                        "2. Pick a source layer.\n" +
                        "   For Move or Copy, a destination layer is also required — " +
                        "only layers with the same geometry type as the source are listed.\n" +
                        "3. Choose All (acts on every feature in the layer) or Filter " +
                        "(narrows by expression).\n" +
                        "4. If using Filter:\n" +
                        "   • Pick a field, operator and value, then tap Apply Filter to " +
                        "build the expression.\n" +
                        "   • The Expression box is filled automatically — you can also " +
                        "type or edit it directly for complex filters.\n" +
                        "   • Typing in the value box shows matching values from the layer " +
                        "as a suggestion list.\n" +
                        "5. Tap Execute.\n" +
                        "   The plugin counts how many features will be affected and shows " +
                        "the total before anything changes.\n" +
                        "6. Review the count in the confirmation screen, then tap Proceed " +
                        "to run or Cancel to go back and adjust."
                    )
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: Theme.mainColor; opacity: 0.3 }

                Label {
                    text: qsTr("IMPORTANT NOTES")
                    font.bold: true; font.pointSize: Theme.defaultFont.pointSize
                    color: Theme.mainColor
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.Wrap
                    font: Theme.tipFont; color: Theme.mainTextColor
                    text: qsTr(
                        "• The action always runs on ALL features matching the expression " +
                        "(or all features in the layer when All is selected). There is no " +
                        "per-feature tick list — this is intentional.\n\n" +
                        "• For Move and Copy: only layers with a matching geometry type " +
                        "(point → point, line → line, polygon → polygon) appear in the " +
                        "destination list. Mismatched layers are excluded automatically.\n" +
                        "  Fields are matched by name — fields that exist in both layers " +
                        "are copied; source fields with no matching name in the destination " +
                        "are silently dropped (shown in the ✘ dropped line below the " +
                        "destination selector).\n\n" +
                        "• ⚠ Performance: counting and executing may be slow on layers " +
                        "with very large numbers of features. Use a filter to narrow the " +
                        "scope where possible.\n\n" +
                        "• Filters are saved per layer and restored automatically the next " +
                        "time you open the plugin. Tap Clear to remove a saved filter."
                    )
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: Theme.mainColor; opacity: 0.3 }

                Label {
                    text: qsTr("OPERATORS")
                    font.bold: true; font.pointSize: Theme.defaultFont.pointSize
                    color: Theme.mainColor
                }
                GridLayout {
                    Layout.fillWidth: true; columns: 2; columnSpacing: 12; rowSpacing: 4
                    property var rows: [
                        ["=",           qsTr("Equal to")],
                        ["<>",          qsTr("Not equal to")],
                        ["> / <",       qsTr("Greater / less than")],
                        [">= / <=",     qsTr("Greater / less than or equal")],
                        ["LIKE",        qsTr("Pattern match — use % as wildcard")],
                        ["IN",          qsTr("Matches any value in a list")],
                        ["NOT IN",      qsTr("Matches none of a list")],
                        ["IS NULL",     qsTr("Field has no value")],
                        ["IS NOT NULL", qsTr("Field has any value")]
                    ]
                    Repeater {
                        model: parent.rows
                        Label { text: modelData[0]; font.family: "monospace"; font.pointSize: Theme.tipFont.pointSize; color: Theme.mainTextColor }
                    }
                    Repeater {
                        model: parent.rows
                        Label { Layout.fillWidth: true; text: modelData[1]; font: Theme.tipFont; color: Theme.secondaryTextColor; wrapMode: Text.Wrap }
                    }
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: Theme.mainColor; opacity: 0.3 }

                Label {
                    text: qsTr("QUOTING RULES")
                    font.bold: true; font.pointSize: Theme.defaultFont.pointSize
                    color: Theme.mainColor
                }
                GridLayout {
                    Layout.fillWidth: true; columns: 2; columnSpacing: 12; rowSpacing: 4
                    property var rows: [
                        ['"fieldname"', qsTr("Field name — always double quotes")],
                        ["'Tom'",       qsTr("Text value — single quotes")],
                        ["42  /  3.14", qsTr("Number — no quotes needed")],
                        ["2024-06-01",  qsTr("Date — auto-wrapped in to_date()")],
                        ["now()",       qsTr("Function call — no quotes, keep the brackets")],
                        ["today()",     qsTr("Today's date as a function")],
                        ["val1, val2",  qsTr("IN list — comma-separated, no outer brackets")]
                    ]
                    Repeater {
                        model: parent.rows
                        Label { text: modelData[0]; font.family: "monospace"; font.pointSize: Theme.tipFont.pointSize; color: Theme.mainTextColor }
                    }
                    Repeater {
                        model: parent.rows
                        Label { Layout.fillWidth: true; text: modelData[1]; font: Theme.tipFont; color: Theme.secondaryTextColor; wrapMode: Text.Wrap }
                    }
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: Theme.mainColor; opacity: 0.3 }

                Label {
                    text: qsTr("EXPRESSION EXAMPLES")
                    font.bold: true; font.pointSize: Theme.defaultFont.pointSize
                    color: Theme.mainColor
                }
                Repeater {
                    model: [
                        [qsTr("\"name\" = 'Tom'"),                    qsTr("Exact text match")],
                        [qsTr("\"name\" <> 'Tom'"),                   qsTr("Not equal")],
                        [qsTr("\"name\" IN ('Tom', 'Alice', 'Bob')"), qsTr("Any of these names")],
                        [qsTr("\"name\" NOT IN ('Tom', 'Alice')"),    qsTr("None of these names")],
                        [qsTr("\"name\" LIKE 'Tom%'"),                qsTr("Starts with 'Tom'")],
                        [qsTr("\"name\" LIKE '%road%'"),              qsTr("Contains 'road'")],
                        [qsTr("\"age\" > 18"),                        qsTr("Numeric comparison")],
                        [qsTr("\"create_date\" < today()"),           qsTr("Before today (date field)")],
                        [qsTr("\"create_date\" > '2024-06-01'"),      qsTr("After a specific date")],
                        [qsTr("\"notes\" IS NULL"),                   qsTr("Field is empty")],
                        [qsTr("\"notes\" IS NOT NULL"),               qsTr("Field has any value")]
                    ]
                    delegate: ColumnLayout {
                        Layout.fillWidth: true; spacing: 1
                        Label { text: modelData[0]; font.family: "monospace"; font.pointSize: Theme.tipFont.pointSize; color: Theme.mainTextColor }
                        Label { Layout.fillWidth: true; text: modelData[1]; font: Theme.tipFont; color: Theme.secondaryTextColor; wrapMode: Text.Wrap; leftPadding: 8 }
                    }
                }

                Item { height: 8 }
            }
        }
    }
}
