// Sentinel Cockpit - The Conductor's Real-Time Strategic Intelligence Dashboard
// Purpose: Real-time D-Bus integration with The Conductor's behavioral analysis
// Doctrine: "From The Oracle's Gaze to The Sentinel's Cockpit"

const { GObject, St, Clutter, GLib, Gio } = imports.gi;
const Main = imports.ui.main;
const PanelMenu = imports.ui.panelMenu;
const PopupMenu = imports.ui.popupMenu;

// D-Bus Configuration
const CONDUCTOR_SERVICE = 'org.jesternet.Conductor';
const CONDUCTOR_PATH = '/org/jesternet/Conductor';
const CONDUCTOR_INTERFACE = 'org.jesternet.Conductor.StrategicIntelligence';

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

        // D-Bus connection
        this._dbusConnection = null;
        this._signalHandlers = [];

        // Initialize D-Bus and start monitoring
        this._initDbus();
        this._startMonitoring();
    }

    _createCockpitInterface() {
        // Set menu to wider dimensions
        this.menu.box.set_width(COCKPIT_WIDTH);

        // Header section
        let headerSection = new PopupMenu.PopupMenuSection();
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

        headerSection.add_child(headerBox);
        this.menu.addMenuItem(headerSection);

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
            this._dbusConnection = Gio.DBus.system;

            // Subscribe to Conductor signals
            this._subscribeToSignals();

            this._updateStatus('🟢 CONDUCTOR CONNECTED - REAL-TIME MONITORING');
        } catch (e) {
            log('[Sentinel Cockpit] D-Bus connection failed: ' + e.message);
            this._updateStatus('🔴 CONDUCTOR OFFLINE - FALLBACK MODE');
        }
    }

    _subscribeToSignals() {
        if (!this._dbusConnection) return;

        // Subscribe to BehavioralAlert signals
        const alertHandler = this._dbusConnection.signal_subscribe(
            CONDUCTOR_SERVICE,
            CONDUCTOR_INTERFACE,
            'BehavioralAlert',
            CONDUCTOR_PATH,
            null,
            Gio.DBusSignalFlags.NONE,
            (connection, sender, path, interface, signal, parameters) => {
                this._onBehavioralAlert(parameters);
            }
        );
        this._signalHandlers.push(alertHandler);

        // Subscribe to ProcessChainUpdate signals
        const processHandler = this._dbusConnection.signal_subscribe(
            CONDUCTOR_SERVICE,
            CONDUCTOR_INTERFACE,
            'ProcessChainUpdate',
            CONDUCTOR_PATH,
            null,
            Gio.DBusSignalFlags.NONE,
            (connection, sender, path, interface, signal, parameters) => {
                this._onProcessChainUpdate(parameters);
            }
        );
        this._signalHandlers.push(processHandler);

        // Subscribe to SystemStatus signals
        const statusHandler = this._dbusConnection.signal_subscribe(
            CONDUCTOR_SERVICE,
            CONDUCTOR_INTERFACE,
            'SystemStatus',
            CONDUCTOR_PATH,
            null,
            Gio.DBusSignalFlags.NONE,
            (connection, sender, path, interface, signal, parameters) => {
                this._onSystemStatus(parameters);
            }
        );
        this._signalHandlers.push(statusHandler);
    }

    _onBehavioralAlert(parameters) {
        try {
            const [ruleId, description, severity, pid, timestamp, details] = parameters.deepUnpack();

            // Add alert to cockpit
            this._addBehavioralAlert({
                ruleId,
                description,
                severity,
                pid,
                timestamp,
                details
            });

            // Update alert badge
            this._updateAlertBadge(severity);

            log(`[Sentinel Cockpit] Behavioral Alert: ${ruleId} (PID: ${pid})`);
        } catch (e) {
            log('[Sentinel Cockpit] Error processing behavioral alert: ' + e.message);
        }
    }

    _onProcessChainUpdate(parameters) {
        try {
            const [pid, parentPid, executionCount, suspiciousPatterns] = parameters.deepUnpack();

            this._updateProcessChain({
                pid,
                parentPid,
                executionCount,
                suspiciousPatterns
            });
        } catch (e) {
            log('[Sentinel Cockpit] Error processing process chain update: ' + e.message);
        }
    }

    _onSystemStatus(parameters) {
        try {
            const [activeRules, eventsProcessed, processChainsTracked] = parameters.deepUnpack();

            this._updateSystemStatus({
                activeRules,
                eventsProcessed,
                processChainsTracked
            });
        } catch (e) {
            log('[Sentinel Cockpit] Error processing system status: ' + e.message);
        }
    }

    _addBehavioralAlert(alert) {
        // Clear alerts section if too many
        if (this._alertsSection._getChildren().length >= 10) {
            this._alertsSection.removeAll();
        }

        // Create alert item
        let alertText = `${this._getSeverityIcon(alert.severity)} ${alert.ruleId}\n`;
        alertText += `PID: ${alert.pid} | ${alert.description}`;

        let alertItem = new PopupMenu.PopupMenuItem(alertText);
        alertItem.style_class = `sentinel-alert-${alert.severity.toLowerCase()}`;

        this._alertsSection.addMenuItem(alertItem);
    }

    _updateProcessChain(chain) {
        // Clear process section
        this._processSection.removeAll();

        // Add process chain item (simplified for demo)
        let chainText = `PID ${chain.pid} → Parent ${chain.parentPid}\n`;
        chainText += `Executions: ${chain.executionCount} | Suspicious: ${chain.suspiciousPatterns}`;

        let chainItem = new PopupMenu.PopupMenuItem(chainText);
        this._processSection.addMenuItem(chainItem);
    }

    _updateSystemStatus(status) {
        // Clear status section
        this._statusSection.removeAll();

        // Add status items
        let rulesItem = new PopupMenu.PopupMenuItem(`📜 Active Rules: ${status.activeRules}`);
        let eventsItem = new PopupMenu.PopupMenuItem(`👁️ Events Processed: ${status.eventsProcessed}`);
        let chainsItem = new PopupMenu.PopupMenuItem(`🔗 Process Chains: ${status.processChainsTracked}`);

        this._statusSection.addMenuItem(rulesItem);
        this._statusSection.addMenuItem(eventsItem);
        this._statusSection.addMenuItem(chainsItem);
    }

    _updateAlertBadge(severity) {
        let currentCount = parseInt(this._alertBadge.text) || 0;
        currentCount++;

        this._alertBadge.text = currentCount.toString();
        this._alertBadge.visible = true;

        // Update icon based on severity
        if (severity === 'CRITICAL') {
            this._icon.icon_name = 'security-low-symbolic';
        } else if (severity === 'HIGH') {
            this._icon.icon_name = 'security-medium-symbolic';
        }
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

    _refreshStrategicIntelligence() {
        // Force refresh of all sections
        this._alertsSection.removeAll();
        this._processSection.removeAll();
        this._statusSection.removeAll();

        this._updateStatus('🔄 REFRESHING STRATEGIC INTELLIGENCE...');

        // In a real implementation, this would query The Conductor for current state
        setTimeout(() => {
            this._updateStatus('🟢 CONDUCTOR ONLINE - BEHAVIORAL ANALYSIS ACTIVE');
        }, 1000);
    }

    _clearAlerts() {
        this._alertsSection.removeAll();
        this._alertBadge.visible = false;
        this._alertBadge.text = '';
        this._icon.icon_name = 'security-high-symbolic';

        this._updateStatus('🟢 ALERTS CLEARED - MONITORING CONTINUES');
    }

    _startMonitoring() {
        // Start periodic status updates
        this._timeout = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, REFRESH_INTERVAL, () => {
            this._refreshStrategicIntelligence();
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

        super.destroy();
    }
});

class Extension {
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

function init() {
    return new Extension();
}