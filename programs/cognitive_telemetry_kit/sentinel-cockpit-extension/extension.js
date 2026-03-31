// Sentinel Cockpit - The Conductor's Real-Time Strategic Intelligence Dashboard
// Purpose: Real-time D-Bus integration with The Conductor's behavioral analysis
// Doctrine: "From The Oracle's Gaze to The Sentinel's Cockpit"

import GObject from 'gi://GObject';
import St from 'gi://St';
import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

// D-Bus Configuration
const SENTINEL_SERVICE = 'org.jesternet.LogSentinel';
const SENTINEL_PATH = '/org/jesternet/LogSentinel';
const SENTINEL_INTERFACE = 'org.jesternet.LogSentinel';

// Cognitive Oracle Configuration (for Cognitive Telemetry)
const ORACLE_SERVICE = 'org.jesternet.CognitiveOracle';
const ORACLE_PATH = '/org/jesternet/CognitiveOracle';
const ORACLE_INTERFACE = 'org.jesternet.CognitiveOracle';

// Cockpit Configuration
const COCKPIT_WIDTH = 600;
const COCKPIT_HEIGHT = 400;
const REFRESH_INTERVAL = 5; // seconds for status updates

const SentinelCockpit = GObject.registerClass(
class SentinelCockpit extends PanelMenu.Button {
    _init() {
        super._init(0.0, 'Sentinel Cockpit');

        // Top bar icon with animated alert state
        this._icon = new St.Icon({
            icon_name: 'security-high-symbolic',
            style_class: 'system-status-icon sentinel-icon',
        });

        // Alert badge for critical behavioral alerts
        this._alertBadge = new St.Label({
            text: '',
            style_class: 'sentinel-alert-badge',
            visible: false,
        });

        let box = new St.BoxLayout();
        box.add_child(this._icon);
        box.add_child(this._alertBadge);
        this.add_child(box);

        // Create wider cockpit menu
        this._createCockpitInterface();

        // D-Bus connections
        this._dbusConnection = null;
        this._oracleConnection = null;
        this._signalHandlers = [];

        // Initialize D-Bus and start monitoring
        this._initDbus();
        this._initOracleDbus();
        this._startMonitoring();
    }

    _createCockpitInterface() {
        // Set menu to wider dimensions
        this.menu.box.set_width(COCKPIT_WIDTH);

        // Header section
        let headerBox = new St.BoxLayout({
            vertical: true,
            style_class: 'sentinel-header',
        });

        // Title
        let title = new St.Label({
            text: '🧠 SENTINEL COCKPIT',
            style_class: 'sentinel-title',
        });
        headerBox.add_child(title);

        // Status line
        this._statusLabel = new St.Label({
            text: '🟢 CONDUCTOR ONLINE - BEHAVIORAL ANALYSIS ACTIVE',
            style_class: 'sentinel-status',
        });
        headerBox.add_child(this._statusLabel);

        let headerItem = new PopupMenu.PopupBaseMenuItem({ reactive: false });
        headerItem.add_child(headerBox);
        this.menu.addMenuItem(headerItem);

        // Behavioral Alerts Section
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem('🚨 BEHAVIORAL ALERTS'));
        this._alertsSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._alertsSection);

        // Process Chains Section
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem('📋 PROCESS CHAINS'));
        this._processSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._processSection);

        // System Status Section
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem('📊 SYSTEM STATUS'));
        this._statusSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._statusSection);

        // Cognitive State Section
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem('🧠 COGNITIVE STATE'));
        this._cognitiveSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._cognitiveSection);

        // Actions Section
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        let actionsSection = new PopupMenu.PopupMenuSection();

        let refreshItem = new PopupMenu.PopupMenuItem('🔄 Refresh Strategic Intelligence');
        refreshItem.connect('activate', () => this._refreshStrategicIntelligence());
        actionsSection.addMenuItem(refreshItem);

        let clearItem = new PopupMenu.PopupMenuItem('🗑️ Clear Alerts');
        clearItem.connect('activate', () => this._clearAlerts());
        actionsSection.addMenuItem(clearItem);

        this.menu.addMenuItem(actionsSection);
    }

    async _initDbus() {
        try {
            this._dbusConnection = Gio.DBus.session;

            // Initial fetch of events and summary
            this._fetchLogSentinelData();

            this._updateStatus('🟢 LOG SENTINEL CONNECTED - REAL-TIME MONITORING');
        } catch (e) {
            log('[Sentinel Cockpit] D-Bus connection failed: ' + e.message);
            this._updateStatus('🔴 LOG SENTINEL OFFLINE - FALLBACK MODE');
        }
    }

    async _initOracleDbus() {
        try {
            this._oracleConnection = Gio.DBus.session;
            log('[Sentinel Cockpit] Connected to Cognitive Oracle for instant telemetry');

            // Initial cognitive state fetch
            this._updateCognitiveState();
        } catch (e) {
            log('[Sentinel Cockpit] Oracle D-Bus connection failed: ' + e.message);
        }
    }

    async _fetchLogSentinelData() {
        if (!this._dbusConnection) return;

        try {
            // Fetch events from LogSentinel
            this._dbusConnection.call(
                SENTINEL_SERVICE,
                SENTINEL_PATH,
                SENTINEL_INTERFACE,
                'GetEvents',
                null,
                null,
                Gio.DBusCallFlags.NONE,
                -1,
                null,
                (connection, result) => {
                    try {
                        const reply = connection.call_finish(result);
                        const eventsJson = reply.deepUnpack()[0];
                        const events = JSON.parse(eventsJson);
                        this._displayEvents(events);
                    } catch (e) {
                        log('[Sentinel Cockpit] Error getting events: ' + e.message);
                    }
                }
            );

            // Fetch summary from LogSentinel
            this._dbusConnection.call(
                SENTINEL_SERVICE,
                SENTINEL_PATH,
                SENTINEL_INTERFACE,
                'GetSummary',
                null,
                null,
                Gio.DBusCallFlags.NONE,
                -1,
                null,
                (connection, result) => {
                    try {
                        const reply = connection.call_finish(result);
                        const summaryJson = reply.deepUnpack()[0];
                        const summary = JSON.parse(summaryJson);
                        this._displaySummary(summary);
                    } catch (e) {
                        log('[Sentinel Cockpit] Error getting summary: ' + e.message);
                    }
                }
            );
        } catch (e) {
            log('[Sentinel Cockpit] Error fetching LogSentinel data: ' + e.message);
        }
    }

    _displayEvents(events) {
        // Clear alerts section
        this._alertsSection.removeAll();

        if (!events || events.length === 0) {
            let noEventsItem = new PopupMenu.PopupMenuItem('No events logged');
            noEventsItem.reactive = false;
            this._alertsSection.addMenuItem(noEventsItem);
            return;
        }

        // Display most recent events (up to 10)
        events.slice(0, 10).forEach(event => {
            let eventText = `${event.timestamp || 'unknown'}\n`;
            eventText += `${event.level || 'INFO'}: ${event.message || 'No message'}`;

            let eventItem = new PopupMenu.PopupMenuItem(eventText);
            eventItem.connect('activate', () => {
                try {
                    const command = `konsole -e bash -c "journalctl -f | grep -i '${event.message.substring(0, 30)}'; exec bash"`;
                    log('[Sentinel Cockpit] Opening event logs');
                    GLib.spawn_command_line_async(command);
                } catch (e) {
                    log('[Sentinel Cockpit] Failed to open logs: ' + e.message);
                }
            });
            this._alertsSection.addMenuItem(eventItem);
        });
    }

    _displaySummary(summary) {
        // Clear status section
        this._statusSection.removeAll();

        if (!summary) {
            let noSummaryItem = new PopupMenu.PopupMenuItem('No summary available');
            noSummaryItem.reactive = false;
            this._statusSection.addMenuItem(noSummaryItem);
            return;
        }

        // Display summary stats
        Object.entries(summary).forEach(([key, value]) => {
            let summaryItem = new PopupMenu.PopupMenuItem(`${key}: ${value}`);
            summaryItem.connect('activate', () => {
                try {
                    const command = `konsole -e bash -c "journalctl -f -u log-sentinel-v2; exec bash"`;
                    log('[Sentinel Cockpit] Opening sentinel logs');
                    GLib.spawn_command_line_async(command);
                } catch (e) {
                    log('[Sentinel Cockpit] Failed to open logs: ' + e.message);
                }
            });
            this._statusSection.addMenuItem(summaryItem);
        });
    }


    _updateStatus(status) {
        this._statusLabel.text = status;
    }

    _getSeverityIcon(severity) {
        switch (severity) {
            case 'CRITICAL': return '🔴';
            case 'HIGH': return '🟠';
            case 'MEDIUM': return '🟡';
            default: return '⚪';
        }
    }

    async _updateCognitiveState() {
        if (!this._oracleConnection) return;

        try {
            // Call Oracle D-Bus method to get current cognitive state
            this._oracleConnection.call(
                ORACLE_SERVICE,
                ORACLE_PATH,
                ORACLE_INTERFACE,
                'GetCurrentState',
                null,
                null,
                Gio.DBusCallFlags.NONE,
                -1,
                null,
                (connection, result) => {
                    try {
                        const reply = connection.call_finish(result);
                        const state = reply.deepUnpack()[0];
                        this._displayCognitiveState(state);
                    } catch (e) {
                        log('[Sentinel Cockpit] Error getting cognitive state: ' + e.message);
                    }
                }
            );

            // Get recent cognitive states history
            this._oracleConnection.call(
                ORACLE_SERVICE,
                ORACLE_PATH,
                ORACLE_INTERFACE,
                'GetRecentStates',
                new GLib.Variant('(i)', [10]),
                null,
                Gio.DBusCallFlags.NONE,
                -1,
                null,
                (connection, result) => {
                    try {
                        const reply = connection.call_finish(result);
                        const statesJson = reply.deepUnpack()[0];
                        const states = JSON.parse(statesJson);
                        this._displayCognitiveHistory(states);
                    } catch (e) {
                        log('[Sentinel Cockpit] Error getting cognitive history: ' + e.message);
                    }
                }
            );
        } catch (e) {
            log('[Sentinel Cockpit] Error updating cognitive state: ' + e.message);
        }
    }

    _displayCognitiveState(state) {
        // Clear cognitive section
        this._cognitiveSection.removeAll();

        // Display current cognitive state with emoji
        let stateEmoji = this._getCognitiveStateEmoji(state);
        let currentStateItem = new PopupMenu.PopupMenuItem(`${stateEmoji} Current: ${state}`);
        currentStateItem.style_class = 'sentinel-cognitive-current';
        this._cognitiveSection.addMenuItem(currentStateItem);
    }

    _displayCognitiveHistory(states) {
        // Display last few cognitive states (already in section)
        if (states.length > 0) {
            let historyItem = new PopupMenu.PopupMenuItem('📜 Recent States:');
            historyItem.reactive = false;
            this._cognitiveSection.addMenuItem(historyItem);

            // Group by PID to show which agent is doing what
            const statesByPid = {};
            states.forEach(state => {
                if (!statesByPid[state.pid]) {
                    statesByPid[state.pid] = [];
                }
                statesByPid[state.pid].push(state);
            });

            // Display states grouped by PID (Oracle returns {pid, state})
            Object.entries(statesByPid).slice(0, 3).forEach(([pid, pidStates]) => {
                const latestState = pidStates[0];
                let emoji = this._getCognitiveStateEmoji(latestState.state);
                let stateText = `  ${emoji} PID ${pid}: ${latestState.state}`;

                let item = new PopupMenu.PopupMenuItem(stateText);
                item.connect('activate', () => {
                    try {
                        // Cognitive states are stored in SQLite, not journalctl
                        // Use file:// URI with immutable flag to allow reads while watcher has db locked
                        const command = `konsole -e bash -c "echo '🧠 Cognitive States for PID ${pid}:'; echo ''; sqlite3 'file:/var/lib/cognitive-watcher/cognitive-states.db?immutable=1' \\"SELECT timestamp_human, TRIM(substr(raw_content, instr(raw_content, '*') + 1, CASE WHEN instr(substr(raw_content, instr(raw_content, '*')), '(') > 0 THEN instr(substr(raw_content, instr(raw_content, '*')), '(') - 1 ELSE length(raw_content) END)) as state FROM cognitive_states WHERE pid=${pid} ORDER BY id DESC LIMIT 50;\\" | column -t -s '|'; echo ''; echo ''; echo 'Or use: cognitive-query session ${pid}'; echo ''; read -p 'Press Enter to continue...'; exec bash"`;
                        log('[Sentinel Cockpit] Opening cognitive states for PID: ' + pid);
                        GLib.spawn_command_line_async(command);
                    } catch (e) {
                        log('[Sentinel Cockpit] Failed to open cognitive states: ' + e.message);
                    }
                });
                this._cognitiveSection.addMenuItem(item);
            });
        }
    }

    _getCognitiveStateEmoji(state) {
        // Map cognitive states to emojis
        const stateMap = {
            'Thinking': '🤔',
            'Pondering': '💭',
            'Channelling': '🌀',
            'Precipitating': '💧',
            'Composing': '✍️',
            'Contemplating': '🧘',
            'Julienning': '🔪',
            'Discombobulating': '😵',
            'Verifying': '✅',
            'Active': '⚡',
            'Reading': '📖',
            'Writing': '📝',
            'Executing': '⚙️',
            'Marinating': '🥘',
            'Booping': '👆',
            'Honking': '📯',
            'Percolating': '☕',
            'Synthesizing': '🧪',
            'Crystallizing': '💎'
        };

        // Try to match the state with known patterns
        for (const [key, emoji] of Object.entries(stateMap)) {
            if (state.includes(key)) {
                return emoji;
            }
        }

        return '🧠'; // Default brain emoji
    }

    _refreshStrategicIntelligence() {
        // Force refresh of all sections
        this._alertsSection.removeAll();
        this._processSection.removeAll();
        this._statusSection.removeAll();
        this._cognitiveSection.removeAll();

        this._updateStatus('🔄 REFRESHING STRATEGIC INTELLIGENCE...');

        // Refresh LogSentinel data
        this._fetchLogSentinelData();

        // Refresh cognitive state
        this._updateCognitiveState();

        setTimeout(() => {
            this._updateStatus('🟢 LOG SENTINEL ONLINE - MONITORING ACTIVE');
        }, 1000);
    }

    _clearAlerts() {
        try {
            if (this._dbusConnection) {
                this._dbusConnection.call(
                    SENTINEL_SERVICE,
                    SENTINEL_PATH,
                    SENTINEL_INTERFACE,
                    'ClearEvents',
                    null,
                    null,
                    Gio.DBusCallFlags.NONE,
                    -1,
                    null,
                    (connection, result) => {
                        try {
                            connection.call_finish(result);
                            log('[Sentinel Cockpit] Cleared LogSentinel events');
                        } catch (e) {
                            log('[Sentinel Cockpit] Error clearing events: ' + e.message);
                        }
                    }
                );
            }

            this._alertsSection.removeAll();
            this._alertBadge.visible = false;
            this._alertBadge.text = '';
            this._icon.icon_name = 'security-high-symbolic';

            this._updateStatus('🟢 ALERTS CLEARED - MONITORING CONTINUES');
        } catch (e) {
            log('[Sentinel Cockpit] Error in clearAlerts: ' + e.message);
        }
    }

    _startMonitoring() {
        // Start periodic status updates
        this._timeout = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, REFRESH_INTERVAL, () => {
            this._refreshStrategicIntelligence();
            return GLib.SOURCE_CONTINUE;
        });

        // Start more frequent cognitive state updates (every 2 seconds)
        this._cognitiveTimeout = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 2, () => {
            this._updateCognitiveState();
            return GLib.SOURCE_CONTINUE;
        });
    }

    destroy() {
        // Clean up signal handlers
        this._signalHandlers.forEach(handler => {
            if (this._dbusConnection && handler) {
                this._dbusConnection.signal_unsubscribe(handler);
            }
        });

        if (this._timeout) {
            GLib.source_remove(this._timeout);
            this._timeout = null;
        }

        if (this._cognitiveTimeout) {
            GLib.source_remove(this._cognitiveTimeout);
            this._cognitiveTimeout = null;
        }

        super.destroy();
    }
});

export default class SentinelCockpitExtension {
    constructor() {
        this._cockpit = null;
    }

    enable() {
        this._cockpit = new SentinelCockpit();
        Main.panel.addToStatusArea('sentinel-cockpit', this._cockpit);
    }

    disable() {
        if (this._cockpit) {
            this._cockpit.destroy();
            this._cockpit = null;
        }
    }
}