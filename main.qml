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
    // Common field name candidates for auto-labelling features
    readonly property var _nameCandidates: ["name", "label", "desc", "description", "title"]

    // Total matched count set by tryExecute() — shown in the feature list dialog
    property int  _totalMatchedCount: 0
    // True when the feature list is capped and more features exist beyond it
    property bool _listTruncated:     false
    // Chunked-loading state — keeps UI responsive while building the checklist
    property bool   _isLoading:  false   // true while counting or chunk-loading checklist
    property var    _loadIter:   null    // active feature iterator (checklist load)
    property int    _loadDone:   0       // features loaded so far (checklist)
    // Expression used to generate the current feature list — used by the
    // "entire dataset" path to act beyond the loaded subset
    property string _activeExpr: ""
    // Async move/copy execution state
    property bool   _isExecuting:     false  // true while move/copy is running
    property bool   _cancelRequested: false  // set to true by Cancel button
    property bool   _isFinalising:    false  // true while batchMode=false commit runs
    property int    _progressCount:   0      // features processed so far
    property var    _copyIter:        null   // open iterator for chunked copy
    property string _execSrcName:     ""     // layer names held across callLater ticks
    property string _execDstName:     ""

    // Feature checklist — { fid, label, checked }
    ListModel { id: featureChecklistModel }

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
        property int    subsetCap:         500   // max features loaded into the review list
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
        height: Math.min(mainWindow.height - 40, 660)
        anchors.centerIn: parent

        // Custom header: title on the left, Help button on the right
        header: Item {
            implicitHeight: headerRow.implicitHeight + 6
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
            featureListDialog.close()        // clean up if back-button closed main first
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
                spacing: 4

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
                    topPadding: 4; bottomPadding: 4
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
                    topPadding: 4; bottomPadding: 4
                    visible: _mode === "move" || _mode === "copy"
                    onCurrentTextChanged: updateFieldMapLabel()
                }

                // ── Filter section (visible when Filter is selected) ───────────
                ColumnLayout {
                    visible: _useFilter
                    Layout.fillWidth: true
                    spacing: 4

                    // Filter section label
                    //Label { text: qsTr("Filter"); font: Theme.tipFont; color: Theme.mainTextColor }

                    // Field + Operator
                    RowLayout {
                        Layout.fillWidth: true; spacing: 4
                        ComboBox {
                            id: fieldSelector
                            Layout.fillWidth: true; model: []; font: Theme.tipFont
                            topPadding: 4; bottomPadding: 4
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
                            topPadding: 4; bottomPadding: 4
                            model: ["=", "<>", ">", "<", ">=", "<=", "LIKE", "IN", "NOT IN", "IS NULL", "IS NOT NULL"]
                            onCurrentTextChanged: {
                                suggestionPopup.close()
                                // Only auto-suggest when the user has already typed something.
                                // Scanning a large layer on an empty field causes freezes.
                                if (currentText !== "IS NULL" && currentText !== "IS NOT NULL"
                                        && valueField.text.trim().length > 1)
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
                            topPadding: 4; bottomPadding: 4
                            placeholderText: {
                                var op = operatorSelector.currentText
                                if (op === "IN" || op === "NOT IN")      return qsTr("val1, val2, val3…")
                                if (_currentFieldType === "datetime")     return qsTr("YYYY-MM-DD HH:MM:SS  or  now()")
                                if (_currentFieldType === "date")         return qsTr("YYYY-MM-DD  or  today()")
                                return qsTr("Value  or  now(), today()…")
                            }
                            onTextEdited: {
                                if (/^\w+\s*\(/.test(text)) { suggestionPopup.close(); return }
                                // Only scan for suggestions once the user has typed ≥ 2 chars —
                                // avoids scanning a large layer on every single keypress.
                                if (text.trim().length >= 2) suggestionTimer.restart()
                                else suggestionPopup.close()
                            }
                            onActiveFocusChanged: {
                                // Don't auto-scan on focus alone — wait for the user to type.
                                if (!activeFocus) suggestionPopup.close()
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

                    // ── Filter action buttons ─────────────────────────────────
                    // Row 1: Set (replace expression) and Clear
                    RowLayout {
                        Layout.fillWidth: true; spacing: 4
                        Button {
                            text: qsTr("Apply Filter")
                            Layout.fillWidth: true; font: Theme.tipFont
                            enabled: fieldSelector.currentText !== ""
                                  && (valueField.text.trim() !== "" || !valueField.visible)
                            onClicked: {
                                suggestionPopup.close()
                                var expr = buildExpression()   // replaces expression box
                                if (expr) saveLayerFilter(layerSelector.currentText)
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
                    // Row 2: AND / OR — append a second (or further) condition
                    RowLayout {
                        Layout.fillWidth: true; spacing: 4
                        Button {
                            text: qsTr("+ AND")
                            Layout.fillWidth: true; font: Theme.tipFont
                            enabled: fieldSelector.currentText !== ""
                                  && (valueField.text.trim() !== "" || !valueField.visible)
                            onClicked: { suggestionPopup.close(); appendCondition("AND") }
                        }
                        Button {
                            text: qsTr("+ OR")
                            Layout.fillWidth: true; font: Theme.tipFont
                            enabled: fieldSelector.currentText !== ""
                                  && (valueField.text.trim() !== "" || !valueField.visible)
                            onClicked: { suggestionPopup.close(); appendCondition("OR") }
                        }
                    }

                    // Editable expression field
                    Label { text: qsTr("Expression (editable):"); font: Theme.tipFont; color: Theme.secondaryTextColor }
                    TextField {
                        id: exprField
                        Layout.fillWidth: true
                        topPadding: 4; bottomPadding: 4
                        font.family: "monospace"; font.pointSize: Theme.tipFont.pointSize
                        placeholderText: qsTr("e.g. \"name\" = 'Tom'")
                        wrapMode: TextInput.Wrap
                    }

                    // Performance note
                    Label {
                        Layout.fillWidth: true
                        text: qsTr("!! Note: may be slow with large numbers of features.")
                        font: Theme.tipFont; color: Theme.secondaryTextColor
                        wrapMode: Text.Wrap; opacity: 0.8
                    }
                }   // end filter section

                // ── Field map (moved here so filter boxes stay visible) ───────
                Label {
                    id: fieldMapLabel
                    Layout.fillWidth: true; text: ""; wrapMode: Text.Wrap
                    font: Theme.tipFont; color: Theme.secondaryTextColor
                    visible: (_mode === "move" || _mode === "copy") && text !== ""
                }

                // ── Review subset (scrollable, bottom of content) ─────────────
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Label {
                        Layout.fillWidth: true
                        text: qsTr("Review subset (recommended when copying/moving large datasets):")
                        font: Theme.tipFont
                        color: Theme.secondaryTextColor
                        wrapMode: Text.Wrap
                        opacity: 0.8
                    }
                    ComboBox {
                        id: subsetCapSelector
                        font: Theme.tipFont
                        topPadding: 4; bottomPadding: 4
                        model: ["50", "100", "200", "500", "1000", "2000", "5000"]
                        Component.onCompleted: {
                            var vals = [50, 100, 200, 500, 1000, 2000, 5000]
                            var idx = vals.indexOf(filterMemory.subsetCap)
                            currentIndex = idx >= 0 ? idx : 3
                        }
                        onCurrentIndexChanged: {
                            var vals = [50, 100, 200, 500, 1000, 2000, 5000]
                            filterMemory.subsetCap = vals[currentIndex]
                        }
                    }
                }

            }   // end inner ColumnLayout
        }   // end ScrollView

        // ── Pinned Execute / Cancel bar ───────────────────────────────────
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            Layout.topMargin: 4
            Layout.bottomMargin: 4
            Layout.leftMargin: 2
            Layout.rightMargin: 2


            // ── Loading indicator (checklist building) ────────────────────
            RowLayout {
                Layout.fillWidth: true
                visible: _isLoading
                spacing: 8
                BusyIndicator { running: _isLoading; implicitWidth: 28; implicitHeight: 28 }
                Label {
                    text: qsTr("Loading features…")
                    font: Theme.tipFont; color: Theme.secondaryTextColor; Layout.fillWidth: true
                }
            }

            // ── Execution progress (move/copy in progress) ────────────────
            RowLayout {
                Layout.fillWidth: true
                visible: _isExecuting
                spacing: 8
                BusyIndicator { running: _isExecuting; implicitWidth: 28; implicitHeight: 28 }
                Label {
                    Layout.fillWidth: true
                    font: Theme.tipFont; color: Theme.secondaryTextColor; wrapMode: Text.Wrap
                    text: _isFinalising
                          ? qsTr("Finishing up — please wait…")
                          : _cancelRequested
                            ? qsTr("Cancelling — finishing current batch…")
                            : _mode === "move"
                              ? qsTr("Moving: %1 features complete…").arg(_progressCount)
                              : qsTr("Copying: %1 features complete…").arg(_progressCount)
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Button {
                    Layout.fillWidth: true
                    font: Theme.defaultFont
                    enabled: !_isLoading
                    text: _isExecuting ? qsTr("Cancel operation") : qsTr("Cancel")
                    onClicked: {
                        if (_isExecuting) {
                            _cancelRequested = true   // honoured at next batch boundary
                        } else {
                            _loadIter = null; _isLoading = false; mainDialog.close()
                        }
                    }
                }
                Button {
                    text: _isLoading ? qsTr("Working…") : qsTr("Execute")
                    Layout.fillWidth: true
                    highlighted: true
                    font: Theme.defaultFont
                    enabled: !_isLoading && !_isExecuting
                    onClicked: tryExecute()
                }
            }
        }

        }   // end outer ColumnLayout
    }   // end mainDialog

    // ── Feature list dialog ───────────────────────────────────────────────────
    // Opens after Execute. Shows matched features as a checklist so the user
    // can deselect individual features before proceeding.
    // Capped at the review subset size — an "entire dataset" button appears when truncated.
    Dialog {
        id: featureListDialog
        parent: mainWindow.contentItem
        modal: true
        font: Theme.defaultFont
        standardButtons: Dialog.NoButton
        anchors.centerIn: parent
        width:  Math.min(mainWindow.width * 0.9, 420)
        height: Math.min(mainWindow.height - 40, 700)
        title: _mode === "move" ? qsTr("Select features to move")
             : _mode === "copy" ? qsTr("Select features to copy")
             : qsTr("Select features to delete")

        ColumnLayout {
            anchors.fill: parent
            spacing: 6

            // ── Summary / truncation warning ──────────────────────────────────
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                font: Theme.tipFont
                color: _listTruncated ? "#e67e22" : Theme.mainTextColor
                text: {
                    var shown  = featureChecklistModel.count
                    var cap    = filterMemory.subsetCap
                    if (_listTruncated)
                        return qsTr("!! Only the first %1 features are loaded (your review " +
                                    "subset). The full matched set is larger. Use the buttons " +
                                    "below to act on this subset or the entire dataset.")
                               .arg(cap)
                    return qsTr("%1 feature(s) matched. Deselect any to exclude.")
                               .arg(shown)
                }
            }

            // ── Expression reminder (filter mode) ─────────────────────────────
            Label {
                Layout.fillWidth: true
                visible: _useFilter && exprField.text.trim() !== ""
                text: exprField.text.trim()
                font.family: "monospace"
                font.pointSize: Theme.tipFont.pointSize
                color: Theme.secondaryTextColor
                wrapMode: Text.Wrap
                elide: Text.ElideRight
                maximumLineCount: 2
            }

            // ── Label field picker ────────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 4
                Label {
                    text: qsTr("Identify by:")
                    font: Theme.tipFont
                    color: Theme.secondaryTextColor
                }
                ComboBox {
                    id: listLabelSelector
                    Layout.fillWidth: true
                    font: Theme.tipFont
                    topPadding: 4; bottomPadding: 4
                    model: ["(auto)"]
                    // onActivated fires only when the user picks from the dropdown —
                    // not during programmatic model/index changes, so no guard needed.
                    onActivated: reloadListLabels()
                }
            }

            // ── All / None + selected count ───────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 4
                Label {
                    id: selectedCountLabel
                    Layout.fillWidth: true
                    font: Theme.tipFont
                    color: Theme.secondaryTextColor
                    text: {
                        var c = 0
                        for (var i = 0; i < featureChecklistModel.count; i++)
                            if (featureChecklistModel.get(i).checked) c++
                        return qsTr("%1 of %2 selected").arg(c).arg(featureChecklistModel.count)
                    }
                }
                Button {
                    text: qsTr("All"); font: Theme.tipFont
                    onClicked: {
                        for (var i = 0; i < featureChecklistModel.count; i++)
                            featureChecklistModel.setProperty(i, "checked", true)
                    }
                }
                Button {
                    text: qsTr("None"); font: Theme.tipFont
                    onClicked: {
                        for (var i = 0; i < featureChecklistModel.count; i++)
                            featureChecklistModel.setProperty(i, "checked", false)
                    }
                }
            }

            // ── Checklist ─────────────────────────────────────────────────────
            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ScrollBar.vertical.policy:   ScrollBar.AsNeeded
                ColumnLayout {
                    width: parent.availableWidth
                    spacing: 0
                    Repeater {
                        model: featureChecklistModel
                        delegate: CheckBox {
                            Layout.fillWidth: true
                            text: model.label
                            checked: model.checked
                            font: Theme.tipFont
                            onCheckedChanged: featureChecklistModel.setProperty(index, "checked", checked)
                        }
                    }
                }
            }

            // ── Proceed (review subset) / Cancel ──────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Button {
                    text: qsTr("Cancel"); Layout.fillWidth: true; font: Theme.defaultFont
                    onClicked: featureListDialog.reject()   // back to main dialog
                }
                Button {
                    // Only show mode-specific label when list is truncated —
                    // otherwise "Proceed" is unambiguous.
                    text: _listTruncated
                          ? (_mode === "delete" ? qsTr("Delete from review subset")
                             : _mode === "move" ? qsTr("Move from review subset")
                             : qsTr("Copy from review subset"))
                          : qsTr("Proceed")
                    Layout.fillWidth: true
                    highlighted: true; font: Theme.defaultFont
                    onClicked: featureListDialog.accept()
                }
            }

            // ── Entire dataset button — only when list is truncated ───────────
            Button {
                id: entireDatasetBtn
                Layout.fillWidth: true
                visible: _listTruncated
                font: Theme.defaultFont
                text: _mode === "delete"
                      ? qsTr("Delete from entire dataset")
                      : _mode === "move"
                        ? qsTr("Move from entire dataset — not recommended")
                        : qsTr("Copy from entire dataset — not recommended")
                // Red for delete, amber for move/copy
                background: Rectangle {
                    radius: 4
                    color: _mode === "delete"
                           ? Qt.rgba(0.75, 0.15, 0.15, 0.9)
                           : Qt.rgba(0.80, 0.45, 0.05, 0.9)
                }
                contentItem: Text {
                    text: entireDatasetBtn.text; font: entireDatasetBtn.font
                    color: "white"
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment:   Text.AlignVCenter
                    wrapMode: Text.Wrap
                }
                onClicked: entireDatasetConfirmDialog.open()
            }
        }

        onAccepted: {
            // Collect IDs of checked features only
            var ids = []
            for (var i = 0; i < featureChecklistModel.count; i++) {
                var item = featureChecklistModel.get(i)
                if (item.checked) ids.push(item.fid)
            }
            if (ids.length === 0) {
                mainWindow.displayToast(qsTr("No features selected — nothing to do."))
                return
            }

            var srcLayer = getLayerByName(layerSelector.currentText)
            if (!srcLayer) return

            if (_useFilter && fieldSelector.currentText && valueField.text.trim() !== "")
                saveLayerFilter(layerSelector.currentText)

            // Act only on the checked feature IDs
            var expr       = "$id IN (" + ids.join(",") + ")"
            var selectedN  = ids.length
            var cap        = filterMemory.subsetCap
            var totalN     = _totalMatchedCount
            var totalStr   = totalN > cap ? qsTr("%1+").arg(cap) : String(totalN)
            var countLabel = (selectedN === featureChecklistModel.count && !_listTruncated)
                             ? String(selectedN)
                             : qsTr("%1 of %2").arg(selectedN).arg(totalStr)

            if (_mode === "move" || _mode === "copy") {
                // Use async batched execution — closes both dialogs and shows
                // progress in the main dialog footer
                featureListDialog.close()
                if (_mode === "move")
                    startBatchMove(srcLayer.name, destLayerSelector.currentText, expr)
                else
                    startBatchCopy(srcLayer.name, destLayerSelector.currentText, expr)
            } else {
                var ok = directDeleteByExpression(srcLayer, expr)
                if (ok)
                    mainWindow.displayToast(
                        qsTr("Deleted %1 feature(s) from '%2'")
                            .arg(countLabel).arg(srcLayer.name))
                mainDialog.close()
            }
        }
    }

    // ── Entire dataset confirm dialog ─────────────────────────────────────────
    // Shown when the user taps "Delete/Move/Copy from entire dataset".
    // Acts on _activeExpr (the original filter expression) with no cap.
    Dialog {
        id: entireDatasetConfirmDialog
        parent: mainWindow.contentItem
        modal: true
        font: Theme.defaultFont
        standardButtons: Dialog.NoButton
        anchors.centerIn: parent
        width: Math.min(mainWindow.width * 0.9, 420)
        title: _mode === "delete" ? qsTr("Delete from entire dataset")
             : _mode === "move"   ? qsTr("Move from entire dataset")
             : qsTr("Copy from entire dataset")

        ColumnLayout {
            width: parent.width
            spacing: 12

            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                font: Theme.tipFont
                color: Theme.mainTextColor
                text: {
                    var warn = (_mode === "move" || _mode === "copy")
                               ? "\n\n" + qsTr("!! This may take a long time or cause the " +
                                               "app to pause on large datasets.")
                               : ""
                    return qsTr("This operation cannot be undone. Proceed?") + warn
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Button {
                    text: qsTr("Cancel"); Layout.fillWidth: true; font: Theme.defaultFont
                    onClicked: entireDatasetConfirmDialog.reject()
                }
                Button {
                    text: qsTr("Proceed"); Layout.fillWidth: true
                    highlighted: true; font: Theme.defaultFont
                    onClicked: entireDatasetConfirmDialog.accept()
                }
            }
        }

        onAccepted: {
            var srcLayer = getLayerByName(layerSelector.currentText)
            if (!srcLayer) return

            if (_mode === "move" || _mode === "copy") {
                // Use async batch path — progress shown in main dialog footer
                entireDatasetConfirmDialog.close()
                featureListDialog.close()
                if (_mode === "move")
                    startBatchMove(srcLayer.name, destLayerSelector.currentText, _activeExpr)
                else
                    startBatchCopy(srcLayer.name, destLayerSelector.currentText, _activeExpr)
            } else {
                var ok = directDeleteByExpression(srcLayer, _activeExpr)
                if (ok)
                    mainWindow.displayToast(
                        qsTr("Deleted all matching features from '%1'").arg(srcLayer.name))
                featureListDialog.close()
                mainDialog.close()
            }
        }
    }

    // ── Functions ─────────────────────────────────────────────────────────────

    // ── Validate then kick off async loading ──────────────────────────────────
    // Sets _isLoading = true, yields to the event loop so the UI updates
    // (spinner appears, button dims), then does the actual work.
    function tryExecute() {
        if (!layerSelector.currentText) {
            mainWindow.displayToast(qsTr("Choose a source layer.")); return
        }
        if ((_mode === "move" || _mode === "copy") && !destLayerSelector.currentText) {
            mainWindow.displayToast(qsTr("No compatible destination layer — must match source geometry type.")); return
        }
        // Empty filter expression = act on all features (same as All mode)
        _isLoading = true
        // Yield one tick so the spinner and "Working…" button appear before we block
        Qt.callLater(doExecute)
    }

    // Runs after the UI has updated. Counts features then starts chunked loading.
    function doExecute() {
        if (!_isLoading) return   // cancelled while waiting
        var srcLayer = getLayerByName(layerSelector.currentText)
        if (!srcLayer) { _isLoading = false; return }
        var expr = (_useFilter && exprField.text.trim() !== "") ? exprField.text.trim() : "1=1"

        var n = countMatchingFeatures(srcLayer, expr)
        _totalMatchedCount = n

        if (n === 0) {
            _isLoading = false
            mainWindow.displayToast(qsTr("No features matched — nothing to do."))
            return
        }
        startChunkedLoad(srcLayer, expr)
    }

    // Initialise the chunked feature load — builds label selector, creates the
    // iterator and schedules the first chunk.
    function startChunkedLoad(layer, expr) {
        _activeExpr = expr          // store for the "entire dataset" path
        featureChecklistModel.clear()
        _listTruncated = false
        _loadDone = 0

        // Rebuild label-field selector (onActivated won't fire for programmatic changes)
        var fieldNames = []
        try { fieldNames = layer.fields.names ? layer.fields.names.slice() : [] } catch(e) {}
        fieldNames.sort()
        listLabelSelector.model = ["(auto)"].concat(fieldNames)
        listLabelSelector.currentIndex = 0

        try {
            _loadIter = LayerUtils.createFeatureIteratorFromExpression(layer, expr)
        } catch(e) {
            _isLoading = false
            mainWindow.displayToast(qsTr("Error reading features: %1").arg(e.toString()))
            return
        }
        Qt.callLater(processLoadChunk)
    }

    // Process one chunk of 25 features then yield back to the event loop.
    // This keeps the UI responsive — the spinner stays animated between chunks.
    function processLoadChunk() {
        if (!_isLoading || !_loadIter) { _loadIter = null; _isLoading = false; return }

        var CHUNK = 25
        var CAP   = filterMemory.subsetCap > 0 ? filterMemory.subsetCap : 500
        var nameCandidates = _nameCandidates

        try {
            var i = 0
            while (i < CHUNK && _loadDone < CAP && _loadIter.hasNext()) {
                var f = _loadIter.next()
                var fid = null
                try { fid = (typeof f.id === "function") ? f.id() : f.id } catch(e) {}

                // Always use the load counter as the fallback label — fids can be
                // negative (e.g. QField temporary IDs) which looks confusing.
                var label = qsTr("Feature %1").arg(_loadDone + 1)
                for (var nc = 0; nc < nameCandidates.length; nc++) {
                    try {
                        var v = f.attribute(nameCandidates[nc])
                        if (v !== null && v !== undefined && String(v).trim() !== "") {
                            label = String(v).trim(); break
                        }
                    } catch(e) {}
                }
                featureChecklistModel.append({
                    fid: fid !== null ? fid : _loadDone, label: label, checked: true
                })
                _loadDone++
                i++
            }
        } catch(e) {
            _loadIter = null; _isLoading = false
            mainWindow.displayToast(qsTr("Error loading features: %1").arg(e.toString()))
            return
        }

        if (_loadIter.hasNext() && _loadDone < CAP) {
            Qt.callLater(processLoadChunk)   // more to load — yield then continue
        } else {
            if (_loadIter.hasNext()) _listTruncated = true
            _loadIter  = null
            _isLoading = false
            featureListDialog.open()
        }
    }

    // Re-label the checklist when the user changes the label-field selector.
    // Uses position-based matching (index) rather than fid lookup — avoids
    // type-mismatch issues with QML/JS integer representations across the boundary.
    // Uses _activeExpr (the expression actually used to load the list) so the
    // iterator returns features in exactly the same order as the original load.
    function reloadListLabels() {
        if (featureChecklistModel.count === 0) return
        var layer = getLayerByName(layerSelector.currentText)
        if (!layer) return

        var chosen         = listLabelSelector.currentText
        var useAuto        = (!chosen || chosen === "(auto)")
        var nameCandidates = _nameCandidates
        var cap            = filterMemory.subsetCap > 0 ? filterMemory.subsetCap : 500
        var expr           = _activeExpr !== "" ? _activeExpr : "1=1"

        // Collect labels in iterator order (same order features were originally loaded)
        var newLabels = []
        try {
            var it      = LayerUtils.createFeatureIteratorFromExpression(layer, expr)
            var scanned = 0
            while (it.hasNext() && scanned < cap) {
                var f   = it.next()
                var lbl = qsTr("Feature %1").arg(scanned + 1)
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
                newLabels.push(lbl)
                scanned++
            }
        } catch(e) {}

        // Update model by index — position i in the iterator = position i in the model
        for (var i = 0; i < featureChecklistModel.count && i < newLabels.length; i++) {
            featureChecklistModel.setProperty(i, "label", newLabels[i])
        }
    }

    // Count features matching expr.
    // Caps at subsetCap+1 — just enough to detect whether the list will be
    // truncated, without iterating thousands of features unnecessarily.
    function countMatchingFeatures(layer, expr) {
        if (!layer) return 0
        var cap = (filterMemory.subsetCap > 0 ? filterMemory.subsetCap : 500)
        // Fast path: entire layer, no filter
        if (expr === "1=1") {
            try {
                var fc = (typeof layer.featureCount === "function")
                         ? layer.featureCount() : layer.featureCount
                if (typeof fc === "number" && fc >= 0) return fc
            } catch(e) {}
        }
        // Filtered: iterate up to cap+1 only
        var count = 0
        try {
            var it = LayerUtils.createFeatureIteratorFromExpression(layer, expr)
            while (it.hasNext() && count <= cap) { it.next(); count++ }
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
            value: valueField.text,
            expr:  exprField.text   // also save the raw expression for direct-entry filters
        }
        filterMemory.layerFilters = JSON.stringify(filters)
    }

    function clearLayerFilter(layerName) {
        if (!layerName) return
        var filters = {}
        try { filters = JSON.parse(filterMemory.layerFilters) } catch(e) {}
        delete filters[layerName]
        filterMemory.layerFilters = JSON.stringify(filters)
        exprField.text = ""
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

        // Restore the raw expression — prefer the saved expr (covers direct-entry filters);
        // fall back to rebuilding from field/op/value if not saved.
        if (saved.expr) {
            exprField.text = saved.expr
        } else {
            var built = buildExpression()
            if (built) exprField.text = built
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
            fieldMapLabel.text = qsTr("!! No editable %1 layers found to copy/move into.").arg(gtName)
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
        if (mapped.length > 0)   parts.push(qsTr("[OK] mapped: ") + mapped.join(", "))
        if (unmapped.length > 0) parts.push(qsTr("[X] dropped: ") + unmapped.join(", "))
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
        // Method 3 (sample-value iterator) removed — it blocks the UI on large layers.
        // Methods 1 and 2 cover all properly-configured layers. Fall back to "text".
        return "text"
    }

    function formatDateValue(val, fieldType) {
        if (val === null || val === undefined) return null
        var keepTime = (fieldType === "datetime")
        function fromDate(d) {
            if (isNaN(d.getTime())) return null
            var y  = d.getFullYear()
            function pad2(n) { return (n < 10 ? "0" + n : String(n)) }
            var mo = pad2(d.getMonth() + 1)
            var dy = pad2(d.getDate())
            if (!keepTime) return y + "-" + mo + "-" + dy
            var h  = pad2(d.getHours())
            var mi = pad2(d.getMinutes())
            var s  = pad2(d.getSeconds())
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

        // Suggestions only fire after 2+ chars typed, so searchText is always non-empty here
        var fieldType  = _currentFieldType
        var isDateType = fieldType === "date" || fieldType === "datetime" || fieldType === "time"
        var iterExpr   = isDateType
            ? 'to_string(date("' + field + '")) ILIKE \'%' + searchText.replace(/'/g, "''") + '%\''
            : 'to_string("' + field + '") ILIKE \'%' + searchText.replace(/'/g, "''") + '%\''
        var seen = {}, values = []
        try {
            var it = LayerUtils.createFeatureIteratorFromExpression(layer, iterExpr)
            var scanned = 0
            while (it.hasNext() && values.length < 10 && scanned < 50) {
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

    // Build a condition string from the current field/operator/value controls
    // WITHOUT writing to exprField — callers decide what to do with the result.
    function buildCondition() {
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

        return expr
    }

    // Build condition and write it to the expression box (replaces any existing expression).
    function buildExpression() {
        var expr = buildCondition()
        if (expr) exprField.text = expr
        return expr
    }

    // Append a new condition to the expression box with the given join word (AND / OR).
    function appendCondition(joinWord) {
        var cond = buildCondition()
        if (!cond) return
        var existing = exprField.text.trim()
        if (existing !== "") {
            // Wrap existing in parens if it isn't already, then append
            var wrapped = (existing.charAt(0) === "(" && existing.charAt(existing.length - 1) === ")")
                          ? existing : "(" + existing + ")"
            exprField.text = wrapped + " " + joinWord + " " + cond
        } else {
            exprField.text = cond
        }
        saveLayerFilter(layerSelector.currentText)
    }

    // ── Async Move — batch loop ───────────────────────────────────────────────
    // Re-runs the expression each batch. Safe because deleted features disappear
    // from future iterator results. Yields between batches via callLater.
    function startBatchMove(srcName, dstName, expr) {
        _isExecuting     = true
        _cancelRequested = false
        _progressCount   = 0
        _execSrcName     = srcName
        _execDstName     = dstName
        Qt.callLater(function() { processMoveNextBatch(expr) })
    }

    function processMoveNextBatch(expr) {
        if (_cancelRequested) {
            _isExecuting = false
            mainWindow.displayToast(
                qsTr("Cancelled — %1 feature(s) moved.").arg(_progressCount))
            mainDialog.close(); return
        }
        var srcLayer = getLayerByName(_execSrcName)
        var dstLayer = getLayerByName(_execDstName)
        if (!srcLayer || !dstLayer) { _isExecuting = false; return }

        // Fixed at 500 — fewer commits than small batches (less SQLite checkpoint
        // overhead) while still updating progress every few seconds.
        var batchSize = 500
        var features  = []
        try {
            var it = LayerUtils.createFeatureIteratorFromExpression(srcLayer, expr)
            var n  = 0
            while (it.hasNext() && n < batchSize) { features.push(it.next()); n++ }
        } catch(e) {
            _isExecuting = false
            mainWindow.displayToast(qsTr("Error reading features: %1").arg(e.toString()))
            return
        }

        if (features.length === 0) {
            _isExecuting = false
            mainWindow.displayToast(
                qsTr("Moved %1 feature(s): '%2' -> '%3'")
                    .arg(_progressCount).arg(_execSrcName).arg(_execDstName))
            mainDialog.close(); return
        }

        var written = writeBatchToLayer(features, srcLayer, dstLayer)

        if (written > 0) {
            var ids = []
            for (var i = 0; i < features.length; i++) {
                try { ids.push((typeof features[i].id === "function")
                                ? features[i].id() : features[i].id) } catch(e) {}
            }
            try {
                if (!srcLayer.isEditable) srcLayer.startEditing()
                srcLayer.selectByExpression("$id IN (" + ids.join(",") + ")")
                srcLayer.deleteSelectedFeatures()
                srcLayer.commitChanges()
                srcLayer.triggerRepaint()
            } catch(e) {
                try { srcLayer.rollBack() } catch(e2) {}
                mainWindow.displayToast(qsTr("Source delete error: %1").arg(e.toString()))
            }
        }
        _progressCount += written
        Qt.callLater(function() { processMoveNextBatch(expr) })
    }

    // ── Async Copy — single open iterator, chunked writes ─────────────────────
    // Keeps one iterator open across callLater ticks — re-running the expression
    // would copy the same features again (duplicates), so single iterator avoids that.
    function startBatchCopy(srcName, dstName, expr) {
        _isExecuting     = true
        _cancelRequested = false
        _progressCount   = 0
        _execSrcName     = srcName
        _execDstName     = dstName

        var srcLayer = getLayerByName(srcName)
        var dstLayer = getLayerByName(dstName)
        if (!srcLayer || !dstLayer) { _isExecuting = false; return }

        try {
            _copyIter = LayerUtils.createFeatureIteratorFromExpression(srcLayer, expr)
        } catch(e) {
            _isExecuting = false
            mainWindow.displayToast(qsTr("Error reading features: %1").arg(e.toString()))
            return
        }
        moveFeatureModel.currentLayer = dstLayer
        moveFeatureModel.batchMode    = true
        Qt.callLater(processCopyNextChunk)
    }

    function processCopyNextChunk() {
        if (_cancelRequested || !_copyIter) {
            moveFeatureModel.batchMode = false
            _copyIter      = null
            _isExecuting   = false
            _isFinalising  = false
            mainWindow.displayToast(_cancelRequested
                ? qsTr("Cancelled — %1 feature(s) copied.").arg(_progressCount)
                : qsTr("Copied %1 feature(s): '%2' -> '%3'")
                      .arg(_progressCount).arg(_execSrcName).arg(_execDstName))
            mainDialog.close(); return
        }

        var srcLayer = getLayerByName(_execSrcName)
        var dstLayer = getLayerByName(_execDstName)
        if (!srcLayer || !dstLayer) {
            moveFeatureModel.batchMode = false; _copyIter = null; _isExecuting = false; return
        }

        var dstFieldNames = []
        try { dstFieldNames = dstLayer.fields.names || [] } catch(e) {}
        var dstFieldIdx = {}
        for (var fi = 0; fi < dstFieldNames.length; fi++)
            dstFieldIdx[dstFieldNames[fi]] = fi
        var srcFieldNames = []
        try { srcFieldNames = srcLayer.fields.names || [] } catch(e) {}

        // Fixed at 100 — iterator stays open between chunks (no re-scan, no per-chunk
        // commit) so each chunk is fast while progress updates are frequent.
        var CHUNK   = 100
        var written = 0
        var hasMore = false

        try {
            var i = 0
            while (i < CHUNK && _copyIter.hasNext()) {
                var srcFeat = _copyIter.next()
                var geom    = srcFeat.geometry
                if (!geom) { i++; continue }
                var newFeat = FeatureUtils.createBlankFeature(dstLayer.fields, geom)
                for (var si = 0; si < srcFieldNames.length; si++) {
                    var fname = srcFieldNames[si]
                    if (dstFieldIdx[fname] === undefined) continue
                    var av = null
                    try { av = srcFeat.attribute(fname) } catch(e) {}
                    if (av !== null && av !== undefined)
                        newFeat.setAttribute(dstFieldIdx[fname], av)
                }
                moveFeatureModel.feature = newFeat
                if (moveFeatureModel.create()) written++
                i++
            }
            hasMore = _copyIter.hasNext()
        } catch(e) {
            moveFeatureModel.batchMode = false; _copyIter = null; _isExecuting = false
            mainWindow.displayToast(qsTr("Error writing features: %1").arg(e.toString()))
            return
        }

        _progressCount += written

        if (!hasMore) {
            // Iterator exhausted — show "Finishing up" then yield so the UI
            // updates before batchMode=false triggers the final blocking commit.
            _isFinalising = true
            _copyIter = null
            Qt.callLater(finaliseCopy)
            return
        }
        Qt.callLater(processCopyNextChunk)
    }

    // ── Finalise copy after last chunk — runs after a UI yield so "Finishing up"
    // is visible before the blocking batchMode=false commit.
    function finaliseCopy() {
        moveFeatureModel.batchMode = false   // triggers final write — may block briefly
        _isExecuting  = false
        _isFinalising = false
        mainWindow.displayToast(
            qsTr("Copied %1 feature(s): '%2' -> '%3'")
                .arg(_progressCount).arg(_execSrcName).arg(_execDstName))
        mainDialog.close()
    }

    // ── Shared: write a batch of features into dstLayer ───────────────────────
    function writeBatchToLayer(features, srcLayer, dstLayer) {
        var dstFieldNames = []
        try { dstFieldNames = dstLayer.fields.names || [] } catch(e) {}
        var dstFieldIdx = {}
        for (var fi = 0; fi < dstFieldNames.length; fi++)
            dstFieldIdx[dstFieldNames[fi]] = fi
        var srcFieldNames = []
        try { srcFieldNames = srcLayer.fields.names || [] } catch(e) {}

        moveFeatureModel.currentLayer = dstLayer
        moveFeatureModel.batchMode    = true
        var written = 0
        for (var i = 0; i < features.length; i++) {
            try {
                var srcFeat = features[i]
                var geom    = srcFeat.geometry
                if (!geom) continue
                var newFeat = FeatureUtils.createBlankFeature(dstLayer.fields, geom)
                for (var si = 0; si < srcFieldNames.length; si++) {
                    var fname = srcFieldNames[si]
                    if (dstFieldIdx[fname] === undefined) continue
                    var av = null
                    try { av = srcFeat.attribute(fname) } catch(e) {}
                    if (av !== null && av !== undefined)
                        newFeat.setAttribute(dstFieldIdx[fname], av)
                }
                moveFeatureModel.feature = newFeat
                if (moveFeatureModel.create()) written++
            } catch(e) { iface.logMessage("writeBatchToLayer error: " + e) }
        }
        moveFeatureModel.batchMode = false
        return written
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
                return true   // caller shows the toast with the "X of Y" message
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
                        "   For Move or Copy a destination layer is also required — " +
                        "only layers with the same geometry type are listed.\n" +
                        "3. Choose All (entire layer) or Filter (by expression).\n" +
                        "4. If using Filter:\n" +
                        "   • Pick a field, operator and value.\n" +
                        "   • Tap Apply Filter to set the expression, or + AND / + OR " +
                        "to add a second (or further) condition to an existing one.\n" +
                        "   • Edit the Expression box directly for anything more complex.\n" +
                        "   • Type at least 2 characters in the value box to see " +
                        "matching values from the layer as suggestions.\n" +
                        "5. Tap Execute. The plugin loads matching features into a list " +
                        "while showing a spinner — this may take a moment on large layers.\n" +
                        "6. Review the feature list:\n" +
                        "   • Use Identify by to choose which field labels each row.\n" +
                        "   • Uncheck any features you want to exclude.\n" +
                        "   • Use All / None to select or clear everything at once.\n" +
                        "7. Tap Proceed to run (shows 'X of Y features' result) or " +
                        "Cancel to go back to the main dialog."
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
                        "• The feature list is capped at 500. If more features match, " +
                        "a warning is shown and Proceed acts on the checked subset only. " +
                        "Use a tighter filter to see the full set.\n\n" +
                        "• Compound filters: use + AND / + OR to chain conditions. " +
                        "Each tap appends a new condition to whatever is already in " +
                        "the Expression box. Apply Filter replaces it.\n\n" +
                        "• today() with = on a datetime field is automatically rewritten " +
                        "to date(\"field\") = today() so the time component is ignored.\n\n" +
                        "• For Move and Copy: only layers with a matching geometry type " +
                        "(point -> point, line -> line, polygon -> polygon) appear in the " +
                        "destination list. Fields are matched by name — unmatched source " +
                        "fields are dropped (shown as [X] dropped below the selector).\n\n" +
                        "• !! Performance: the feature list loads in small chunks to keep " +
                        "the UI responsive, but executing Move or Copy on very large " +
                        "matched sets may still cause a pause. Use a filter to narrow " +
                        "the scope where possible.\n\n" +
                        "• Filters are saved per layer and restored next session. " +
                        "Tap Clear to remove a saved filter."
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
