import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore
import Theme
import org.qfield
import org.qgis

Item {
    property var mainWindow: iface.mainWindow()

    // When true the confirm dialog runs the direct-expression path (no checklist)
    property bool   directMode: false
    property string directExpr: ""

    // Cached field type ("text"/"date"/"datetime"/"time"/"numeric") for the
    // currently selected field.  Updated only when the layer or field selector
    // changes — avoids calling detectFieldType() (which may run an iterator)
    // inside frequently-re-evaluated QML bindings.
    property string _currentFieldType: "text"

    // Guard flag: true while updateFieldSelector() is rebuilding the label-field
    // ComboBox model so that onCurrentTextChanged does not fire reapplyLabels().
    property bool _labelModelUpdating: false

    // Feature checklist — { id: int, label: string, checked: bool }
    ListModel { id: deleteFeaturesModel }

    // FeatureModel used to write features into the destination layer (move/copy mode)
    FeatureModel {
        id: moveFeatureModel
        project: qgisProject
    }

    // ── Persistent filter memory ──────────────────────────────────────────────
    // Stores a JSON map of  layerName → { field, op, value }
    // so each layer's last-used filter is restored automatically next session.
    // featureCap limits how many features are loaded into the checklist at once.
    Settings {
        id: filterMemory
        category: "CopyMoveDeleteFeatures"
        property string layerFilters:      "{}"
        property int    featureCap:        500
        property string layerLabelFields:  "{}"   // layerName → chosen label field name
        property string lastLayerName:     ""     // remembered source layer
        property string lastDestLayerName: ""     // remembered destination layer
        property string lastModeName:      ""     // "delete" | "copy" | "move"
    }

    Component.onCompleted: {
        iface.addItemToPluginsToolbar(openButton)
    }

    Timer {
        id: suggestionTimer
        interval: 600   // wait 600 ms after last keystroke before scanning
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
        title: modeMove.checked
               ? qsTr("Move features — CopyMoveDeleteFeatures")
               : modeCopy.checked ? qsTr("Copy features — CopyMoveDeleteFeatures")
               : qsTr("Delete features — CopyMoveDeleteFeatures")
        standardButtons: Dialog.Ok | Dialog.Cancel
        font: Theme.defaultFont
        width:  Math.min(mainWindow.width * 0.9, 420)
        height: Math.min(implicitHeight, mainWindow.height - 40)
        anchors.centerIn: parent

        onAccepted: {
            if (!layerSelector.currentText) return
            // directMode is opened directly by the "Delete/Copy/Move all ▶▶" button,
            // not via the main dialog OK button — so OK always means checklist mode here.
            directMode = false
            var anyChecked = false
            for (var i = 0; i < deleteFeaturesModel.count; i++)
                if (deleteFeaturesModel.get(i).checked) { anyChecked = true; break }
            if (!anyChecked) {
                mainWindow.displayToast(qsTr("Tick at least one feature."))
                return
            }
            if ((modeMove.checked || modeCopy.checked) && !destLayerSelector.currentText) {
                mainWindow.displayToast(qsTr("Choose a destination layer."))
                return
            }
            confirmDialog.open()
        }
        onOpened: {
            // Restore last-used mode
            var m = filterMemory.lastModeName
            if      (m === "copy")  modeCopy.checked  = true
            else if (m === "move")  modeMove.checked  = true
            else                    modeDelete.checked = true
        }
        onClosed: {
            suggestionPopup.close()
            // Persist current selections so they survive close/reopen
            filterMemory.lastLayerName     = layerSelector.currentText
            filterMemory.lastDestLayerName = destLayerSelector.currentText
            filterMemory.lastModeName      = modeMove.checked ? "move"
                                           : modeCopy.checked ? "copy" : "delete"
        }

        ScrollView {
            anchors.fill: parent
            contentWidth: availableWidth
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            ColumnLayout {
                width: mainDialog.availableWidth
                spacing: 6

                // ── Mode ──────────────────────────────────────────────────────
                // Flow wraps to a second line automatically on narrow screens
                Flow {
                    Layout.fillWidth: true
                    spacing: 4
                    RadioButton {
                        id: modeDelete
                        text: qsTr("Delete")
                        font: Theme.tipFont
                        checked: true
                    }
                    RadioButton {
                        id: modeCopy
                        text: qsTr("Copy to layer")
                        font: Theme.tipFont
                    }
                    RadioButton {
                        id: modeMove
                        text: qsTr("Move to layer")
                        font: Theme.tipFont
                    }
                }

                // ── Source layer ──────────────────────────────────────────────
                Label { text: qsTr("Source layer"); font: Theme.tipFont; color: Theme.mainTextColor }
                ComboBox {
                    id: layerSelector
                    Layout.fillWidth: true
                    model: []
                    font: Theme.tipFont
                    onCurrentTextChanged: {
                        updateFieldSelector()
                        updateDestLayerSelector()
                        restoreLayerFilter(currentText)   // re-applies saved filter (or clears)
                    }
                }

                // ── Destination layer (copy/move modes) ───────────────────────
                Label {
                    text: qsTr("Destination layer")
                    font: Theme.tipFont
                    color: Theme.mainTextColor
                    visible: modeMove.checked || modeCopy.checked
                }
                ComboBox {
                    id: destLayerSelector
                    Layout.fillWidth: true
                    model: []
                    font: Theme.tipFont
                    visible: modeMove.checked || modeCopy.checked
                    onCurrentTextChanged: updateFieldMapLabel()
                }
                Label {
                    id: fieldMapLabel
                    Layout.fillWidth: true
                    text: ""
                    font: Theme.tipFont
                    color: Theme.secondaryTextColor
                    wrapMode: Text.Wrap
                    visible: (modeMove.checked || modeCopy.checked) && text !== ""
                }

                // ── Filter ────────────────────────────────────────────────────
                RowLayout {
                    Layout.fillWidth: true
                    Label {
                        text: qsTr("Filter (optional)")
                        font: Theme.tipFont
                        color: Theme.mainTextColor
                        Layout.fillWidth: true
                    }
                    Button {
                        text: qsTr("?")
                        font: Theme.tipFont
                        flat: true
                        onClicked: helpDialog.open()
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    ComboBox {
                        id: fieldSelector
                        Layout.fillWidth: true
                        model: []
                        font: Theme.tipFont
                        displayText: currentText || qsTr("Field…")
                        onCurrentTextChanged: {
                            valueField.text = ""
                            suggestionPopup.close()
                            // Update the cached field type — do this here (user action) not
                            // in a placeholderText binding so the iterator only runs once.
                            var lyr = getLayerByName(layerSelector.currentText)
                            _currentFieldType = lyr ? detectFieldType(lyr, currentText) : "text"
                        }
                    }
                    ComboBox {
                        id: operatorSelector
                        Layout.preferredWidth: 80
                        font: Theme.tipFont
                        model: ["=", "<>", ">", "<", ">=", "<=", "LIKE", "IN", "NOT IN", "IS NULL", "IS NOT NULL"]
                        onCurrentTextChanged: {
                            suggestionPopup.close()
                            if (currentText !== "IS NULL" && currentText !== "IS NOT NULL"
                                    && valueField.text.trim() === "")
                                suggestionTimer.restart()
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    Item {
                        Layout.fillWidth: true
                        implicitHeight: valueField.implicitHeight
                        visible: operatorSelector.currentText !== "IS NULL"
                               && operatorSelector.currentText !== "IS NOT NULL"

                        TextField {
                            id: valueField
                            anchors.fill: parent
                            font: Theme.tipFont
                            placeholderText: {
                                // Use _currentFieldType (cached) — never call detectFieldType()
                                // here as this binding re-evaluates on every keystroke.
                                var op = operatorSelector.currentText
                                if (op === "IN" || op === "NOT IN")
                                    return qsTr("val1, val2, val3…")
                                if (_currentFieldType === "datetime") return qsTr("YYYY-MM-DD HH:MM:SS  or  now()")
                                if (_currentFieldType === "date")     return qsTr("YYYY-MM-DD  or  today()")
                                return qsTr("Value  or  now(), today()…")
                            }
                            onTextEdited: {
                                if (text.indexOf("(") !== -1) { suggestionPopup.close(); return }
                                suggestionTimer.restart()
                            }
                            onActiveFocusChanged: {
                                if (activeFocus && text.indexOf("(") === -1) suggestionTimer.restart()
                                else suggestionPopup.close()
                            }
                        }

                        Popup {
                            id: suggestionPopup
                            y: valueField.height + 2
                            x: 0
                            width: valueField.width
                            height: Math.min(suggestionList.contentHeight + 8, 180)
                            padding: 4
                            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                            background: Rectangle {
                                color: Theme.mainBackgroundColor
                                border.color: Theme.mainColor
                                border.width: 1
                                radius: 4
                            }
                            ListView {
                                id: suggestionList
                                anchors.fill: parent
                                clip: true
                                model: []
                                delegate: ItemDelegate {
                                    width: suggestionList.width
                                    text: modelData
                                    font: Theme.tipFont
                                    highlighted: hovered
                                    onClicked: {
                                        var op = operatorSelector.currentText
                                        if (op === "IN" || op === "NOT IN") {
                                            // Append to existing comma list
                                            var cur = valueField.text.trim()
                                            valueField.text = cur === "" ? modelData
                                                                         : cur + ", " + modelData
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

                    Item { Layout.fillWidth: true; visible: operatorSelector.currentText === "IS NULL" || operatorSelector.currentText === "IS NOT NULL" }

                    Button {
                        text: qsTr("▶"); font: Theme.tipFont
                        Layout.preferredWidth: 36
                        enabled: fieldSelector.currentText !== ""
                              && (valueField.text.trim() !== "" || !valueField.visible)
                        onClicked: {
                            suggestionPopup.close()
                            var expr = buildExpression()
                            if (expr) {
                                exprField.text = expr
                                saveLayerFilter(layerSelector.currentText)
                                loadFeatures(expr)
                            }
                        }
                    }
                    Button {
                        text: qsTr("✕"); font: Theme.tipFont
                        Layout.preferredWidth: 36
                        onClicked: {
                            valueField.text = ""
                            exprField.text  = ""
                            suggestionPopup.close()
                            clearLayerFilter(layerSelector.currentText)
                            loadFeatures(null)
                        }
                    }
                }

                // ── Editable expression field ─────────────────────────────────
                // Filled automatically by the structured filter above.
                // Can also be typed/edited directly for complex expressions.
                Label {
                    id: exprPreviewLabel  // kept for backward-compat with restoreLayerFilter etc.
                    text: ""
                    visible: false        // hidden — exprField is the visible one now
                }
                Label {
                    text: qsTr("Expression (editable):")
                    font: Theme.tipFont
                    color: Theme.secondaryTextColor
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    TextField {
                        id: exprField
                        Layout.fillWidth: true
                        font.family: "monospace"
                        font.pointSize: Theme.tipFont.pointSize
                        placeholderText: qsTr("e.g. \"name\" = 'Tom'")
                        wrapMode: TextInput.Wrap
                    }
                    Button {
                        text: qsTr("▶")
                        font: Theme.tipFont
                        Layout.preferredWidth: 36
                        enabled: exprField.text.trim() !== ""
                        onClicked: {
                            var e = exprField.text.trim()
                            if (e) loadFeatures(e)
                        }
                    }
                }

                // ── Direct action — bypasses checklist, acts on full matched set ──
                // Delete uses selectByExpression → deleteSelectedFeatures (pure C++).
                // Copy/Move iterates all matched features — no cap applied.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    visible: exprField.text.trim() !== ""
                    Label {
                        text: qsTr("All matching:")
                        font: Theme.tipFont
                        color: Theme.secondaryTextColor
                    }
                    Button {
                        text: modeDelete.checked ? qsTr("Delete all ▶▶")
                            : modeCopy.checked   ? qsTr("Copy all ▶▶")
                                                 : qsTr("Move all ▶▶")
                        font: Theme.tipFont
                        onClicked: {
                            var e = exprField.text.trim()
                            if (!e) return
                            if ((modeMove.checked || modeCopy.checked) &&
                                    !destLayerSelector.currentText) {
                                mainWindow.displayToast(qsTr("Choose a destination layer."))
                                return
                            }
                            directMode = true
                            directExpr = e
                            confirmDialog.open()
                        }
                    }
                }

                // ── Feature cap (editable, for testing) ──────────────────────
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Label {
                        text: qsTr("Cap:")
                        font: Theme.tipFont
                        color: Theme.secondaryTextColor
                    }
                    TextField {
                        id: capField
                        Layout.preferredWidth: 70
                        font: Theme.tipFont
                        text: String(filterMemory.featureCap)
                        inputMethodHints: Qt.ImhDigitsOnly
                        validator: IntValidator { bottom: 1; top: 999999 }
                        onEditingFinished: {
                            var n = parseInt(text)
                            if (!isNaN(n) && n > 0) filterMemory.featureCap = n
                        }
                    }
                    Label {
                        text: qsTr("features (reload to apply)")
                        font: Theme.tipFont
                        color: Theme.secondaryTextColor
                        opacity: 0.6
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }
                }

                // ── Label field chooser ───────────────────────────────────────
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Label {
                        text: qsTr("Label:")
                        font: Theme.tipFont
                        color: Theme.secondaryTextColor
                    }
                    ComboBox {
                        id: labelFieldSelector
                        Layout.fillWidth: true
                        font: Theme.tipFont
                        model: ["(auto)"]
                        onCurrentTextChanged: {
                            // Skip while updateFieldSelector() is rebuilding the model —
                            // only act on genuine user selection changes.
                            if (_labelModelUpdating) return
                            if (deleteFeaturesModel.count > 0) reapplyLabels()
                            saveLabelField(layerSelector.currentText)
                        }
                    }
                }

                // ── Checklist ─────────────────────────────────────────────────
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Label {
                        Layout.fillWidth: true
                        text: deleteFeaturesModel.count > 0
                              ? qsTr("%1 feature(s):").arg(deleteFeaturesModel.count)
                              : qsTr("No features loaded")
                        font: Theme.tipFont; color: Theme.secondaryTextColor; wrapMode: Text.Wrap
                    }
                    Button {
                        text: qsTr("All");  font: Theme.tipFont
                        Layout.preferredWidth: 44
                        visible: deleteFeaturesModel.count > 0
                        onClicked: { for (var i = 0; i < deleteFeaturesModel.count; i++) deleteFeaturesModel.setProperty(i, "checked", true) }
                    }
                    Button {
                        text: qsTr("None"); font: Theme.tipFont
                        Layout.preferredWidth: 50
                        visible: deleteFeaturesModel.count > 0
                        onClicked: { for (var i = 0; i < deleteFeaturesModel.count; i++) deleteFeaturesModel.setProperty(i, "checked", false) }
                    }
                }

                ScrollView {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(deleteFeaturesModel.count * 44, 200)
                    visible: deleteFeaturesModel.count > 0
                    clip: true
                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                    ScrollBar.vertical.policy:   ScrollBar.AsNeeded
                    ColumnLayout {
                        width: mainDialog.availableWidth
                        spacing: 0
                        Repeater {
                            model: deleteFeaturesModel
                            delegate: CheckBox {
                                Layout.fillWidth: true
                                text: model.label
                                checked: model.checked
                                font: Theme.tipFont
                                onCheckedChanged: deleteFeaturesModel.setProperty(index, "checked", checked)
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Confirm dialog ────────────────────────────────────────────────────────
    Dialog {
        id: confirmDialog
        parent: mainWindow.contentItem
        modal: true
        font: Theme.defaultFont
        standardButtons: Dialog.Ok | Dialog.Cancel
        anchors.centerIn: parent
        width: Math.min(mainWindow.width * 0.9, 420)
        title: {
            if (directMode)
                return modeMove.checked ? qsTr("Move ALL matching?")
                     : modeCopy.checked ? qsTr("Copy ALL matching?")
                                        : qsTr("Delete ALL matching?")
            return modeMove.checked
                   ? qsTr("Move to '%1'?").arg(destLayerSelector.currentText)
                   : modeCopy.checked
                     ? qsTr("Copy to '%1'?").arg(destLayerSelector.currentText)
                     : qsTr("Delete from '%1'?").arg(layerSelector.currentText)
        }

        Timer {
            id: confirmTimer; interval: 7000
            onTriggered: { confirmDialog.reject(); mainWindow.displayToast(qsTr("Timed out.")) }
        }
        ColumnLayout {
            width: parent.width; spacing: 10
            Label {
                Layout.fillWidth: true
                text: {
                    if (directMode) {
                        var verb = modeMove.checked ? qsTr("move")
                                 : modeCopy.checked ? qsTr("copy") : qsTr("delete")
                        var where = (modeMove.checked || modeCopy.checked)
                            ? qsTr(" → '%1'").arg(destLayerSelector.currentText) : ""
                        return qsTr("About to %1 ALL features from '%2'%3 matching:\n\n%4\n\nType 'a' to confirm:")
                            .arg(verb).arg(layerSelector.currentText).arg(where).arg(directExpr)
                    }
                    var n = 0
                    for (var i = 0; i < deleteFeaturesModel.count; i++)
                        if (deleteFeaturesModel.get(i).checked) n++
                    var action = modeMove.checked
                        ? qsTr("move %1 feature(s) from '%2' → '%3'")
                              .arg(n).arg(layerSelector.currentText).arg(destLayerSelector.currentText)
                        : modeCopy.checked
                          ? qsTr("copy %1 feature(s) from '%2' → '%3'")
                                .arg(n).arg(layerSelector.currentText).arg(destLayerSelector.currentText)
                          : qsTr("delete %1 feature(s) from '%2'")
                                .arg(n).arg(layerSelector.currentText)
                    return qsTr("About to %1.\nType 'a' to confirm:").arg(action)
                }
                wrapMode: Text.Wrap; font: Theme.tipFont; color: Theme.mainTextColor
            }
            TextField {
                id: confirmInput; Layout.fillWidth: true
                placeholderText: "a"; font: Theme.defaultFont
            }
        }
        onOpened: { confirmInput.text = ""; confirmTimer.restart() }
        onClosed:  { confirmTimer.stop(); directMode = false }
        onAccepted: {
            if (confirmInput.text.toLowerCase() !== "a") {
                mainWindow.displayToast(qsTr("Wrong confirmation — cancelled.")); return
            }
            var srcLayer = getLayerByName(layerSelector.currentText)
            if (!srcLayer) return
            if (fieldSelector.currentText && valueField.text.trim() !== "")
                saveLayerFilter(layerSelector.currentText)

            var count = -1

            if (directMode) {
                // ── Direct path: act on all features matching directExpr ────
                if (modeMove.checked || modeCopy.checked) {
                    var dstLayerD = getLayerByName(destLayerSelector.currentText)
                    if (!dstLayerD) return
                    count = directCopyMoveByExpression(srcLayer, dstLayerD, directExpr, modeMove.checked)
                    if (count > 0) {
                        var verbD = modeMove.checked ? qsTr("Moved") : qsTr("Copied")
                        mainWindow.displayToast(
                            qsTr("%1 %2 feature(s): '%3' → '%4'")
                                .arg(verbD).arg(count).arg(srcLayer.name).arg(dstLayerD.name))
                    }
                } else {
                    count = directDeleteByExpression(srcLayer, directExpr)
                    // count is true/false for direct delete — toast is shown inside the function
                }
            } else {
                // ── Checklist path: act on ticked items ────────────────────
                if (modeMove.checked || modeCopy.checked) {
                    var dstLayer = getLayerByName(destLayerSelector.currentText)
                    if (!dstLayer) return
                    var doDelete = modeMove.checked
                    count = copyOrMove(srcLayer, dstLayer, doDelete)
                    if (count > 0) {
                        var verb = doDelete ? qsTr("Moved") : qsTr("Copied")
                        mainWindow.displayToast(
                            qsTr("%1 %2 feature(s): '%3' → '%4'")
                                .arg(verb).arg(count).arg(srcLayer.name).arg(dstLayer.name))
                    }
                } else {
                    count = deleteChecked(srcLayer)
                    if (count > 0)
                        mainWindow.displayToast(
                            qsTr("Deleted %1 feature(s) from '%2'").arg(count).arg(srcLayer.name))
                }
                if (count === 0) mainWindow.displayToast(qsTr("Nothing changed."))
            }
        }
    }

    // ── Functions ─────────────────────────────────────────────────────────────

    function updateLayers() {
        var layers = ProjectUtils.mapLayers(qgisProject)
        var names = []
        for (var id in layers) { var l = layers[id]; if (l && l.supportsEditing) names.push(l.name) }
        names.sort()
        layerSelector.model = names
        // Restore last-used source layer; fall back to first if it no longer exists
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
            _labelModelUpdating = true
            labelFieldSelector.model = ["(auto)"]
            labelFieldSelector.currentIndex = 0
            _labelModelUpdating = false
            return
        }
        var names = []
        try { names = layer.fields.names ? layer.fields.names.slice() : [] } catch(e) {}
        names.sort()
        fieldSelector.model = names
        fieldSelector.currentIndex = names.length > 0 ? 0 : -1

        // Cache the field type for the first field so placeholderText is correct immediately.
        // fieldSelector.onCurrentTextChanged also does this, but may not fire if the same
        // field name is selected after a layer switch.
        _currentFieldType = (names.length > 0) ? detectFieldType(layer, names[0]) : "text"

        // Populate label-field selector inside the guard so onCurrentTextChanged
        // does not fire reapplyLabels() during model/index changes.
        _labelModelUpdating = true
        var labelNames = ["(auto)"].concat(names)
        labelFieldSelector.model = labelNames
        var savedLabel = loadLabelField(layerSelector.currentText)
        var idx = labelNames.indexOf(savedLabel)
        labelFieldSelector.currentIndex = idx >= 0 ? idx : 0
        _labelModelUpdating = false
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

    // ── Label field persistence ───────────────────────────────────────────────

    function saveLabelField(layerName) {
        if (!layerName) return
        var map = {}
        try { map = JSON.parse(filterMemory.layerLabelFields) } catch(e) {}
        var chosen = labelFieldSelector.currentText
        if (!chosen || chosen === "(auto)")
            delete map[layerName]
        else
            map[layerName] = chosen
        filterMemory.layerLabelFields = JSON.stringify(map)
    }

    function loadLabelField(layerName) {
        if (!layerName) return "(auto)"
        var map = {}
        try { map = JSON.parse(filterMemory.layerLabelFields) } catch(e) {}
        return map[layerName] || "(auto)"
    }

    // Re-label already-loaded checklist items without reloading from layer.
    // Called when the user changes the label field selector mid-session.
    function reapplyLabels() {
        var layer = getLayerByName(layerSelector.currentText)
        if (!layer) return
        var chosen = labelFieldSelector.currentText
        var useAuto = (!chosen || chosen === "(auto)")
        var nameCandidates = ["name", "label", "desc", "description", "title"]

        // We need the original features to re-read attributes.
        // Re-iterate using the current expression (or all).
        var expr = exprField.text.trim()
        var iterExpr = expr !== "" ? expr : "1=1"
        var cap = (filterMemory.featureCap > 0) ? filterMemory.featureCap : 500

        // Build a map of fid → label from a fresh iterator pass
        var labelMap = {}
        try {
            var it = LayerUtils.createFeatureIteratorFromExpression(layer, iterExpr)
            var scanned = 0
            while (it.hasNext() && scanned < cap) {
                var f = it.next()
                var fid = null
                try { fid = (typeof f.id === 'function') ? f.id() : f.id } catch(e) {}
                if (fid === null) { scanned++; continue }
                var lbl = qsTr("Feature %1").arg(fid)
                if (useAuto) {
                    for (var nc = 0; nc < nameCandidates.length; nc++) {
                        try {
                            var v = f.attribute(nameCandidates[nc])
                            if (v !== null && v !== undefined && String(v).trim() !== "") {
                                lbl = String(v).trim(); break
                            }
                        } catch(e) {}
                    }
                } else {
                    try {
                        var cv = f.attribute(chosen)
                        if (cv !== null && cv !== undefined && String(cv).trim() !== "")
                            lbl = String(cv).trim()
                    } catch(e) {}
                }
                labelMap[fid] = lbl
                scanned++
            }
        } catch(e) {}

        // Update the model in-place
        for (var i = 0; i < deleteFeaturesModel.count; i++) {
            var item = deleteFeaturesModel.get(i)
            if (labelMap[item.id] !== undefined)
                deleteFeaturesModel.setProperty(i, "label", labelMap[item.id])
        }
    }

    // Restore saved filter for this layer, then auto-apply it to the checklist.
    // Called after the field selector model is populated so indices are valid.
    function restoreLayerFilter(layerName) {
        var filters = {}
        try { filters = JSON.parse(filterMemory.layerFilters) } catch(e) {}
        var saved = filters[layerName]

        if (!saved || !saved.field) {
            // No saved filter — load all features
            valueField.text = ""
            exprField.text  = ""
            loadFeatures(null)
            return
        }

        // Restore field
        var fieldIdx = fieldSelector.model.indexOf(saved.field)
        fieldSelector.currentIndex = fieldIdx >= 0 ? fieldIdx : 0

        // Restore operator
        var ops = ["=", "<>", ">", "<", ">=", "<=", "LIKE", "IN", "NOT IN", "IS NULL", "IS NOT NULL"]
        var opIdx = ops.indexOf(saved.op)
        operatorSelector.currentIndex = opIdx >= 0 ? opIdx : 0

        // Restore value
        valueField.text = saved.value || ""

        // Auto-apply
        var expr = buildExpression()
        if (expr) {
            exprPreviewLabel.text = expr
            exprField.text        = expr
            loadFeatures(expr)
        } else {
            loadFeatures(null)
        }
    }

    // Populate destination selector with layers that share the same geometry type
    function updateDestLayerSelector() {
        var srcLayer = getLayerByName(layerSelector.currentText)
        if (!srcLayer) { destLayerSelector.model = []; return }
        var srcGt = srcLayer.geometryType ? srcLayer.geometryType() : -1

        var layers = ProjectUtils.mapLayers(qgisProject)
        var names = []
        for (var id in layers) {
            var l = layers[id]
            if (!l || !l.supportsEditing) continue
            if (l.name === layerSelector.currentText) continue   // exclude source
            var gt = l.geometryType ? l.geometryType() : -1
            if (gt === srcGt) names.push(l.name)
        }
        names.sort()
        destLayerSelector.model = names
        // Restore last-used destination layer; fall back to first if gone
        var savedDest = names.indexOf(filterMemory.lastDestLayerName)
        destLayerSelector.currentIndex = savedDest >= 0 ? savedDest : (names.length > 0 ? 0 : -1)
        updateFieldMapLabel()
    }

    // Show which source fields will map to destination fields
    function updateFieldMapLabel() {
        if (!modeMove.checked && !modeCopy.checked) { fieldMapLabel.text = ""; return }
        var srcLayer = getLayerByName(layerSelector.currentText)
        var dstLayer = getLayerByName(destLayerSelector.currentText)
        if (!srcLayer || !dstLayer) { fieldMapLabel.text = ""; return }

        var srcNames = []
        var dstNames = []
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
    // Returns "date", "datetime", "time", or "text" for a given field.
    // Tries three methods in order: typeName(), QVariant type number, sample value.
    function detectFieldType(layer, fieldName) {
        if (!layer || !fieldName) return "text"
        try {
            var fields = layer.fields
            if (!fields) return "text"

            // Method 1 — typeName() string (most reliable when available)
            try {
                var fld = fields.field(fieldName)
                if (fld) {
                    var tn = typeof fld.typeName === 'function' ? fld.typeName() : fld.typeName
                    if (tn) {
                        tn = String(tn).toLowerCase()
                        if (tn === "datetime" || tn === "timestamp") return "datetime"
                        if (tn === "date")                           return "date"
                        if (tn === "time")                           return "time"
                        if (tn.indexOf("int") !== -1 || tn === "double" ||
                            tn === "real" || tn === "float" || tn === "decimal") return "numeric"
                        return "text"
                    }
                }
            } catch(e) {}

            // Method 2 — QVariant type number
            try {
                var fld2 = fields.field(fieldName)
                if (fld2 && fld2.type !== undefined) {
                    var t = fld2.type
                    if (t === 16) return "datetime"   // QVariant::DateTime
                    if (t === 14) return "date"        // QVariant::Date
                    if (t === 15) return "time"        // QVariant::Time
                    if (t === 2 || t === 3 || t === 4 || t === 5 || t === 6) return "numeric"
                }
            } catch(e) {}
        } catch(e) {}

        // Method 3 — infer from a sample value
        // QField returns datetime fields as JS Date objects, or as strings in
        // various formats ("2024-04-18T10:00", "Sat Apr 18 20:18:52 2026 GMT+0100", …)
        try {
            var it = LayerUtils.createFeatureIteratorFromExpression(
                layer, '"' + fieldName + '" IS NOT NULL')
            if (it.hasNext()) {
                var rawVal = it.next().attribute(fieldName)

                // Case A: QML returned an actual Date object
                if (rawVal instanceof Date) {
                    return isNaN(rawVal.getTime()) ? "text" : "datetime"
                }

                var sv = String(rawVal || "").trim()

                // Case B: ISO format  "2024-04-18" or "2024-04-18T10:00:00"
                if (/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/.test(sv)) return "datetime"
                if (/^\d{4}-\d{2}-\d{2}$/.test(sv))                 return "date"

                // Case C: JS Date string "Sat Apr 18 20:18:52 2026 GMT+0100"
                // Only attempt if string is non-numeric and long enough to be a date
                if (sv.length > 10 && isNaN(parseFloat(sv))) {
                    try {
                        var pd = new Date(sv)
                        if (!isNaN(pd.getTime()) &&
                            pd.getFullYear() > 1900 && pd.getFullYear() < 2200)
                            return "datetime"
                    } catch(e) {}
                }
            }
        } catch(e) {}

        return "text"
    }

    // Format any date/datetime value for display and expression building.
    // - datetime fields → "YYYY-MM-DD HH:MM:SS"  (time preserved)
    // - date fields     → "YYYY-MM-DD"
    // Handles JS Date objects, ISO strings, and verbose strings like
    // "Sat Apr 18 20:18:52 2026 GMT+0100".
    function formatDateValue(val, fieldType) {
        if (val === null || val === undefined) return null
        var keepTime = (fieldType === "datetime")

        // ── Helper: format a JS Date into the right string ────────────────────
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

        // Case A: actual JS Date object (QField returns datetime fields as these)
        if (val instanceof Date) return fromDate(val)

        var s = String(val).trim()

        // Case B: already ISO format — "2024-04-18" or "2024-04-18T20:18:52" etc.
        if (/^\d{4}-\d{2}-\d{2}/.test(s)) {
            if (!keepTime) return s.substring(0, 10)
            // normalise separator and trim to seconds
            var norm = s.replace("T", " ")
            return /\d{2}:\d{2}/.test(norm) ? norm.substring(0, 19) : norm.substring(0, 10)
        }

        // Case C: verbose JS Date string or any other parseable format
        try {
            var d = new Date(s)
            if (!isNaN(d.getTime()) && d.getFullYear() > 1900 && d.getFullYear() < 2200)
                return fromDate(d)
        } catch(e) {}

        return s   // fallback: return as-is
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
        if (searchText.indexOf("(") !== -1) return

        // Use cached field type — avoids a redundant iterator scan on every keystroke
        var fieldType  = _currentFieldType
        var isDateType = fieldType === "date" || fieldType === "datetime" || fieldType === "time"

        // For date fields: filter by string representation of the date part
        // For text/numeric: use ILIKE
        var iterExpr
        if (searchText === "") {
            iterExpr = '"' + field + '" IS NOT NULL'
        } else if (isDateType) {
            // Match against the date portion as a string
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
                    // Format date values as YYYY-MM-DD so they paste correctly
                    var s = isDateType ? formatDateValue(raw, fieldType) : String(raw).trim()
                    if (s && s !== "NULL" && !seen[s]) { seen[s] = true; values.push(s) }
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
        var isFunction = raw.indexOf("(") !== -1   // e.g. now(), today(), to_date(...)

        // Use cached field type (set when fieldSelector.currentText changes)
        var fieldType  = _currentFieldType
        var isDateType = fieldType === "date" || fieldType === "datetime" || fieldType === "time"

        var quotedVal
        var expr

        if (op === "LIKE") {
            var v = raw.indexOf("%") === -1
                    ? "%" + raw.replace(/'/g, "''") + "%"
                    : raw.replace(/'/g, "''")
            expr = '"' + field + '" ILIKE \'' + v + '\''

        } else if (op === "IN" || op === "NOT IN") {
            // Split on commas (or semicolons), quote each part by type
            var parts = raw.split(/\s*[,;]\s*/).map(function(p) { return p.trim() })
                           .filter(function(p) { return p !== "" })
            if (parts.length === 0) return ""
            var inVals = parts.map(function(p) {
                var pIsNum = !isNaN(parseFloat(p)) && isFinite(p)
                var pIsFn  = p.indexOf("(") !== -1
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
            // Function calls (now(), today(), to_date(...)) and plain numbers — pass through
            expr = '"' + field + '" ' + op + ' ' + raw

        } else if (isDateType) {
            // Clean up the value — converts "Sat Apr 18 20:18:52 2026 GMT+0100"
            // and any other date format to a normalised string.
            // For datetime fields this preserves the time: "YYYY-MM-DD HH:MM:SS"
            var cleanDate = formatDateValue(raw, fieldType) || raw

            // Does the cleaned value carry a time component?
            var hasTime = /\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/.test(cleanDate)

            if (fieldType === "datetime" && hasTime && op === "=") {
                // Exact datetime equality — use format_date() on both sides to
                // avoid millisecond or timezone mismatches with to_datetime()
                expr = "format_date(\"" + field + "\", 'yyyy-MM-dd HH:mm:ss') = '" +
                       cleanDate.replace(/'/g, "''") + "'"
            } else if (fieldType === "datetime" && hasTime) {
                // Datetime range comparison (< > <= >=) — to_datetime() is fine
                var safeDT = "to_datetime('" + cleanDate.replace(/'/g, "''") + "')"
                expr = '"' + field + '" ' + op + ' ' + safeDT
            } else if (fieldType === "datetime" && op === "=") {
                // Date-only value on datetime field → day-level equality
                var safeDateD = "to_date('" + cleanDate.replace(/'/g, "''") + "')"
                expr = 'date("' + field + '") = ' + safeDateD
            } else {
                // Plain date field, or datetime with date-only + range operator
                var safeDateVal = "to_date('" + cleanDate.replace(/'/g, "''") + "')"
                expr = '"' + field + '" ' + op + ' ' + safeDateVal
            }

        } else {
            quotedVal = "'" + raw.replace(/'/g, "''") + "'"
            expr = '"' + field + '" ' + op + ' ' + quotedVal
        }

        exprField.text = expr
        return expr
    }

    function loadFeatures(filterExpr) {
        deleteFeaturesModel.clear()
        // expression field is already set by buildExpression() or restoreLayerFilter()
        var layer = getLayerByName(layerSelector.currentText)
        if (!layer) return

        var cap = (filterMemory.featureCap > 0) ? filterMemory.featureCap : 500
        var features = []
        var truncated = false

        // Use the iterator for BOTH paths so the cap can stop the loop early.
        // selectAll()+selectedFeatures() fetches everything in one blocking C++ call
        // before JS can intervene — the iterator fetches one feature at a time,
        // so we can break at the cap without hanging on large layers.
        var iterExpr = filterExpr ? filterExpr : "1=1"
        try {
            var it = LayerUtils.createFeatureIteratorFromExpression(layer, iterExpr)
            while (it.hasNext()) {
                if (features.length >= cap) { truncated = true; break }
                features.push(it.next())
            }
        } catch(e) {
            mainWindow.displayToast(qsTr("Expression error: %1").arg(e.toString())); return
        }
        if (filterExpr && features.length === 0) {
            mainWindow.displayToast(qsTr("No features matched.")); return
        }

        if (truncated)
            mainWindow.displayToast(
                qsTr("Showing first %1 of more features — use a filter to narrow results.").arg(cap))

        if (!features || features.length === 0) return

        var chosenLabelField = labelFieldSelector.currentText
        var useAuto = (!chosenLabelField || chosenLabelField === "(auto)")
        var nameCandidates = ["name", "label", "desc", "description", "title"]

        for (var i = 0; i < features.length; i++) {
            var f = features[i]
            var fid = null
            try { fid = (typeof f.id === 'function') ? f.id() : f.id } catch(e) {}
            var label = qsTr("Feature %1").arg(fid !== null ? fid : i + 1)

            if (useAuto) {
                // Try common name-like fields in order
                for (var nc = 0; nc < nameCandidates.length; nc++) {
                    try {
                        var val = f.attribute(nameCandidates[nc])
                        if (val !== null && val !== undefined && String(val).trim() !== "") {
                            label = String(val).trim(); break
                        }
                    } catch(e) {}
                }
            } else {
                // Use the field the user chose
                try {
                    var cv = f.attribute(chosenLabelField)
                    if (cv !== null && cv !== undefined && String(cv).trim() !== "")
                        label = String(cv).trim()
                } catch(e) {}
            }

            deleteFeaturesModel.append({ id: fid !== null ? fid : i, label: label, checked: true })
        }
    }

    function deleteChecked(layer) {
        var ids = checkedIds()
        if (ids.length === 0) return 0
        try {
            if (!layer.isEditable) layer.startEditing()
            layer.selectByExpression("$id IN (" + ids.join(",") + ")")
            layer.triggerRepaint()
            var ok = layer.deleteSelectedFeatures()
            if (ok) { layer.commitChanges(); layer.triggerRepaint(); loadFeatures(null); return ids.length }
            layer.rollBack()
            mainWindow.displayToast(qsTr("Delete failed."))
            return -1
        } catch(e) {
            try { layer.rollBack() } catch(e2) {}
            mainWindow.displayToast(qsTr("Error: %1").arg(e.toString()))
            return -1
        }
    }

    // Copy checked features into dstLayer (matching fields by name).
    // If deleteSource is true, also delete them from srcLayer (= Move).
    // If deleteSource is false, originals are kept            (= Copy).
    function copyOrMove(srcLayer, dstLayer, deleteSource) {
        var ids = checkedIds()
        if (ids.length === 0) return 0

        // ── 1. Load the features we want to move ───────────────────────────
        var expr = "$id IN (" + ids.join(",") + ")"
        var features = []
        try {
            var it = LayerUtils.createFeatureIteratorFromExpression(srcLayer, expr)
            while (it.hasNext()) features.push(it.next())
        } catch(e) {
            mainWindow.displayToast(qsTr("Could not read features: %1").arg(e.toString()))
            return -1
        }
        if (features.length === 0) return 0

        // ── 2. Build field name→index map for destination ──────────────────
        var dstFieldNames = []
        try { dstFieldNames = dstLayer.fields.names || [] } catch(e) {}
        var dstFieldIdx = {}
        for (var fi = 0; fi < dstFieldNames.length; fi++)
            dstFieldIdx[dstFieldNames[fi]] = fi

        var srcFieldNames = []
        try { srcFieldNames = srcLayer.fields.names || [] } catch(e) {}

        // ── 3. Write features into destination layer ───────────────────────
        moveFeatureModel.currentLayer = dstLayer
        moveFeatureModel.batchMode = true
        var written = 0

        for (var i = 0; i < features.length; i++) {
            try {
                var srcFeat = features[i]
                var geom = srcFeat.geometry
                if (!geom) continue

                var newFeat = FeatureUtils.createBlankFeature(dstLayer.fields, geom)

                // Copy attributes where field names match
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
                iface.logMessage("Move feature error: " + e)
            }
        }
        moveFeatureModel.batchMode = false

        if (written === 0) {
            mainWindow.displayToast(qsTr("No features could be written to destination."))
            return 0
        }

        // ── 4. Delete originals from source (Move only) ───────────────────
        if (!deleteSource) {
            // Copy mode — originals stay, just reload the checklist
            loadFeatures(null)
            return written
        }

        try {
            if (!srcLayer.isEditable) srcLayer.startEditing()
            srcLayer.selectByExpression(expr)
            srcLayer.triggerRepaint()
            var ok = srcLayer.deleteSelectedFeatures()
            if (ok) {
                srcLayer.commitChanges()
                srcLayer.triggerRepaint()
                loadFeatures(null)
                return written
            }
            srcLayer.rollBack()
            mainWindow.displayToast(
                qsTr("Copied %1 feature(s) to destination but could not delete from source.").arg(written))
            return written
        } catch(e) {
            try { srcLayer.rollBack() } catch(e2) {}
            mainWindow.displayToast(qsTr("Source delete error: %1").arg(e.toString()))
            return written
        }
    }

    function checkedIds() {
        var ids = []
        for (var i = 0; i < deleteFeaturesModel.count; i++) {
            var item = deleteFeaturesModel.get(i)
            if (item.checked) ids.push(item.id)
        }
        return ids
    }

    // ── Direct-expression actions (bypass checklist, no cap) ──────────────────

    // Delete ALL features matching expr.
    // Uses selectByExpression + deleteSelectedFeatures — pure QGIS C++, no JS loop.
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
                loadFeatures(null)
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

    // Copy/Move ALL features matching expr — iterates full matched set, no cap.
    function directCopyMoveByExpression(srcLayer, dstLayer, expr, deleteSource) {
        // ── 1. Iterate ALL matching features ──────────────────────────────
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

        // ── 2. Build destination field map ────────────────────────────────
        var dstFieldNames = []
        try { dstFieldNames = dstLayer.fields.names || [] } catch(e) {}
        var dstFieldIdx = {}
        for (var fi = 0; fi < dstFieldNames.length; fi++)
            dstFieldIdx[dstFieldNames[fi]] = fi

        var srcFieldNames = []
        try { srcFieldNames = srcLayer.fields.names || [] } catch(e) {}

        // ── 3. Write features into destination ────────────────────────────
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

        // ── 4. Delete originals (Move only) ───────────────────────────────
        if (!deleteSource) {
            loadFeatures(null)
            return written
        }

        try {
            if (!srcLayer.isEditable) srcLayer.startEditing()
            srcLayer.selectByExpression(expr)
            srcLayer.triggerRepaint()
            var ok2 = srcLayer.deleteSelectedFeatures()
            if (ok2) {
                srcLayer.commitChanges()
                srcLayer.triggerRepaint()
                loadFeatures(null)
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
            anchors.fill: parent
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ScrollBar.vertical.policy:   ScrollBar.AsNeeded

            ColumnLayout {
                width: helpDialog.availableWidth
                spacing: 14

                // ── How to use ────────────────────────────────────────────────
                Label {
                    text: qsTr("HOW TO USE")
                    font.bold: true; font.pointSize: Theme.defaultFont.pointSize
                    color: Theme.mainColor
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.Wrap
                    font: Theme.tipFont; color: Theme.mainTextColor
                    text: qsTr(
                        "1. Pick a source layer — features load in the checklist.\n" +
                        "2. Optionally set a filter to narrow which features are shown.\n" +
                        "3. Tick/untick features, or use All / None.\n" +
                        "4. Choose Delete, Copy to layer, or Move to layer.\n" +
                        "5. Type 'abc' to confirm (7-second timeout).\n\n" +
                        "Filters are saved per layer and restored automatically next session. " +
                        "Press Clear to remove a saved filter."
                    )
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: Theme.mainColor; opacity: 0.3 }

                // ── Operators ─────────────────────────────────────────────────
                Label {
                    text: qsTr("OPERATORS")
                    font.bold: true; font.pointSize: Theme.defaultFont.pointSize
                    color: Theme.mainColor
                }
                // operator table — two columns
                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: 12; rowSpacing: 4

                    property var rows: [
                        ["=",          qsTr("Equal to")],
                        ["<>",         qsTr("Not equal to")],
                        ["> / <",      qsTr("Greater / less than")],
                        [">= / <=",    qsTr("Greater / less than or equal")],
                        ["LIKE",       qsTr("Pattern match — use % as wildcard")],
                        ["IN",         qsTr("Matches any value in a list")],
                        ["NOT IN",     qsTr("Matches none of a list")],
                        ["IS NULL",    qsTr("Field has no value")],
                        ["IS NOT NULL",qsTr("Field has any value")]
                    ]

                    Repeater {
                        model: parent.rows
                        Label {
                            text: modelData[0]
                            font.family: "monospace"
                            font.pointSize: Theme.tipFont.pointSize
                            color: Theme.mainTextColor
                        }
                    }
                    // second column — descriptions
                    Repeater {
                        model: parent.rows
                        Label {
                            Layout.fillWidth: true
                            text: modelData[1]
                            font: Theme.tipFont
                            color: Theme.secondaryTextColor
                            wrapMode: Text.Wrap
                        }
                    }
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: Theme.mainColor; opacity: 0.3 }

                // ── Quoting rules ─────────────────────────────────────────────
                Label {
                    text: qsTr("QUOTING RULES")
                    font.bold: true; font.pointSize: Theme.defaultFont.pointSize
                    color: Theme.mainColor
                }
                GridLayout {
                    Layout.fillWidth: true
                    columns: 2; columnSpacing: 12; rowSpacing: 4

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
                        Label {
                            text: modelData[0]
                            font.family: "monospace"
                            font.pointSize: Theme.tipFont.pointSize
                            color: Theme.mainTextColor
                        }
                    }
                    Repeater {
                        model: parent.rows
                        Label {
                            Layout.fillWidth: true
                            text: modelData[1]
                            font: Theme.tipFont
                            color: Theme.secondaryTextColor
                            wrapMode: Text.Wrap
                        }
                    }
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: Theme.mainColor; opacity: 0.3 }

                // ── Examples ──────────────────────────────────────────────────
                Label {
                    text: qsTr("EXPRESSION EXAMPLES")
                    font.bold: true; font.pointSize: Theme.defaultFont.pointSize
                    color: Theme.mainColor
                }
                Repeater {
                    model: [
                        [qsTr("name = 'Tom'"),                    qsTr("Exact text match")],
                        [qsTr("name <> 'Tom'"),                   qsTr("Not equal")],
                        [qsTr("name IN ('Tom', 'Alice', 'Bob')"), qsTr("Any of these names")],
                        [qsTr("name NOT IN ('Tom', 'Alice')"),    qsTr("None of these names")],
                        [qsTr("name LIKE 'Tom%'"),                qsTr("Starts with 'Tom'")],
                        [qsTr("name LIKE '%road%'"),              qsTr("Contains 'road'")],
                        [qsTr("age > 18"),                        qsTr("Numeric comparison")],
                        [qsTr("age >= 18 AND age <= 65"),         qsTr("Numeric range (type full expr)")],
                        [qsTr("create_date < today()"),                   qsTr("Before today (date field)")],
                        [qsTr("create_date > '2024-06-01'"),              qsTr("After a specific date")],
                        [qsTr("create_date = '2024-06-01'"),              qsTr("On a date — day-level match for datetime")],
                        [qsTr("edit_date = '2026-04-18 20:18:52'"),       qsTr("Exact datetime match")],
                        [qsTr("edit_date > '2026-04-18 00:00:00'"),       qsTr("After a specific date+time")],
                        [qsTr("notes IS NULL"),                   qsTr("Field is empty")],
                        [qsTr("notes IS NOT NULL"),               qsTr("Field has any value")]
                    ]
                    delegate: ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Label {
                            text: modelData[0]
                            font.family: "monospace"
                            font.pointSize: Theme.tipFont.pointSize
                            color: Theme.mainTextColor
                        }
                        Label {
                            Layout.fillWidth: true
                            text: modelData[1]
                            font: Theme.tipFont
                            color: Theme.secondaryTextColor
                            wrapMode: Text.Wrap
                            leftPadding: 8
                        }
                    }
                }

                // bottom padding
                Item { height: 8 }
            }
        }
    }
}
