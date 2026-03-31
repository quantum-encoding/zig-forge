/**
 * Claude Shepherd GNOME Extension
 *
 * Monitor and control Claude Code instances from your desktop.
 * Communicates with claude-shepherd daemon via Unix socket.
 */

import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import GObject from 'gi://GObject';
import St from 'gi://St';
import Clutter from 'gi://Clutter';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as MessageTray from 'resource:///org/gnome/shell/ui/messageTray.js';

const SOCKET_PATH = '/tmp/claude-shepherd.sock';
const PID_FILE = '/tmp/claude-shepherd.pid';
const REFRESH_INTERVAL = 2000; // 2 seconds

// Daemon binaries
const DAEMON_POLLING = 'claude-shepherd';
const DAEMON_EBPF = 'claude-shepherd-ebpf';

// Mode detection file (written by daemon)
const MODE_FILE = '/tmp/claude-shepherd-mode';

// Agent status colors
const STATUS_COLORS = {
    running: '#4CAF50',
    waiting_permission: '#FF9800',
    paused: '#2196F3',
    completed: '#9E9E9E',
    failed: '#F44336',
};

const ClaudeShepherdIndicator = GObject.registerClass(
class ClaudeShepherdIndicator extends PanelMenu.Button {
    _init() {
        super._init(0.0, 'Claude Shepherd');

        // Create panel icon
        this._icon = new St.Icon({
            icon_name: 'system-run-symbolic',
            style_class: 'system-status-icon',
        });
        this.add_child(this._icon);

        // State
        this._agents = [];
        this._pendingPermissions = [];
        this._daemonRunning = false;
        this._daemonMode = 'none'; // 'none', 'polling', 'ebpf'
        this._refreshTimeout = null;

        // Build menu
        this._buildMenu();

        // Start refresh loop
        this._startRefresh();
    }

    _buildMenu() {
        // Header
        let headerBox = new St.BoxLayout({
            style_class: 'claude-shepherd-header',
            vertical: false,
        });

        let headerLabel = new St.Label({
            text: 'Claude Shepherd',
            style_class: 'claude-shepherd-title',
            y_align: Clutter.ActorAlign.CENTER,
        });
        headerBox.add_child(headerLabel);

        let headerItem = new PopupMenu.PopupBaseMenuItem({ reactive: false });
        headerItem.add_child(headerBox);
        this.menu.addMenuItem(headerItem);

        // Status indicator
        this._statusItem = new PopupMenu.PopupMenuItem('Daemon: Checking...');
        this._statusItem.sensitive = false;
        this.menu.addMenuItem(this._statusItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Active Agents section
        this._agentsSection = new PopupMenu.PopupMenuSection();
        let agentsLabel = new PopupMenu.PopupMenuItem('Active Agents');
        agentsLabel.sensitive = false;
        agentsLabel.label.style = 'font-weight: bold; color: #888;';
        this.menu.addMenuItem(agentsLabel);
        this.menu.addMenuItem(this._agentsSection);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Pending Permissions section
        this._permissionsSection = new PopupMenu.PopupMenuSection();
        let permLabel = new PopupMenu.PopupMenuItem('Pending Permissions');
        permLabel.sensitive = false;
        permLabel.label.style = 'font-weight: bold; color: #FF9800;';
        this.menu.addMenuItem(permLabel);
        this.menu.addMenuItem(this._permissionsSection);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Quick Actions
        let actionsLabel = new PopupMenu.PopupMenuItem('Quick Actions');
        actionsLabel.sensitive = false;
        actionsLabel.label.style = 'font-weight: bold; color: #888;';
        this.menu.addMenuItem(actionsLabel);

        // Queue Task button
        let queueItem = new PopupMenu.PopupMenuItem('Queue New Task...');
        queueItem.connect('activate', () => this._showQueueDialog());
        this.menu.addMenuItem(queueItem);

        // Approve All button
        let approveAllItem = new PopupMenu.PopupMenuItem('Approve All Pending');
        approveAllItem.connect('activate', () => this._approveAll());
        this.menu.addMenuItem(approveAllItem);

        // Send Command button
        let commandItem = new PopupMenu.PopupMenuItem('Send Command...');
        commandItem.connect('activate', () => this._showCommandDialog());
        this.menu.addMenuItem(commandItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Daemon control section
        let daemonLabel = new PopupMenu.PopupMenuItem('Daemon Control');
        daemonLabel.sensitive = false;
        daemonLabel.label.style = 'font-weight: bold; color: #888;';
        this.menu.addMenuItem(daemonLabel);

        // Mode indicator
        this._modeItem = new PopupMenu.PopupMenuItem('Mode: Not Running');
        this._modeItem.sensitive = false;
        this.menu.addMenuItem(this._modeItem);

        // Start Polling Mode button
        this._startPollingItem = new PopupMenu.PopupMenuItem('Start (Polling Mode)');
        this._startPollingItem.connect('activate', () => this._startDaemon('polling'));
        this.menu.addMenuItem(this._startPollingItem);

        // Start eBPF Mode button (with root icon)
        this._startEbpfItem = new PopupMenu.PopupMenuItem('Start (eBPF Mode)');
        this._startEbpfItem.connect('activate', () => this._startDaemon('ebpf'));
        this.menu.addMenuItem(this._startEbpfItem);

        // Stop button
        this._stopItem = new PopupMenu.PopupMenuItem('Stop Daemon');
        this._stopItem.connect('activate', () => this._stopDaemon());
        this.menu.addMenuItem(this._stopItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Open Logs
        let logsItem = new PopupMenu.PopupMenuItem('View Logs');
        logsItem.connect('activate', () => this._openLogs());
        this.menu.addMenuItem(logsItem);
    }

    _startRefresh() {
        this._refresh();
        this._refreshTimeout = GLib.timeout_add(GLib.PRIORITY_DEFAULT, REFRESH_INTERVAL, () => {
            this._refresh();
            return GLib.SOURCE_CONTINUE;
        });
    }

    _stopRefresh() {
        if (this._refreshTimeout) {
            GLib.source_remove(this._refreshTimeout);
            this._refreshTimeout = null;
        }
    }

    _refresh() {
        this._checkDaemon();
        this._updateAgents();
        this._updatePermissions();
        this._updateIcon();
    }

    _checkDaemon() {
        try {
            let pidFile = Gio.File.new_for_path(PID_FILE);
            if (pidFile.query_exists(null)) {
                let [success, contents] = pidFile.load_contents(null);
                if (success) {
                    let pid = parseInt(new TextDecoder().decode(contents).trim());
                    // Check if process exists
                    let procFile = Gio.File.new_for_path(`/proc/${pid}`);
                    this._daemonRunning = procFile.query_exists(null);

                    // Detect mode from status file
                    if (this._daemonRunning) {
                        this._detectMode();
                    }
                }
            } else {
                this._daemonRunning = false;
                this._daemonMode = 'none';
            }
        } catch (e) {
            this._daemonRunning = false;
            this._daemonMode = 'none';
        }

        // Update UI based on state
        this._updateDaemonUI();
    }

    _detectMode() {
        // Try to detect mode from status JSON
        try {
            let statusFile = Gio.File.new_for_path('/tmp/claude-shepherd-status.json');
            if (statusFile.query_exists(null)) {
                let [success, contents] = statusFile.load_contents(null);
                if (success) {
                    let status = JSON.parse(new TextDecoder().decode(contents));
                    // Check if ebpf mode marker exists
                    if (status.mode) {
                        this._daemonMode = status.mode;
                    } else {
                        // Default to polling if no mode specified
                        this._daemonMode = 'polling';
                    }
                    return;
                }
            }
        } catch (e) {
            // Ignore
        }

        // Fallback: check process name
        try {
            let [success, stdout] = GLib.spawn_command_line_sync('pgrep -a claude-shepherd');
            if (success) {
                let output = new TextDecoder().decode(stdout);
                if (output.includes('ebpf')) {
                    this._daemonMode = 'ebpf';
                } else {
                    this._daemonMode = 'polling';
                }
            }
        } catch (e) {
            this._daemonMode = 'polling';
        }
    }

    _updateDaemonUI() {
        if (this._daemonRunning) {
            this._statusItem.label.text = 'Daemon: Running';
            this._statusItem.label.style = 'color: #4CAF50;';

            // Show mode
            if (this._daemonMode === 'ebpf') {
                this._modeItem.label.text = 'Mode: eBPF (Event-Driven)';
                this._modeItem.label.style = 'color: #9C27B0;'; // Purple for eBPF
            } else {
                this._modeItem.label.text = 'Mode: Polling';
                this._modeItem.label.style = 'color: #2196F3;'; // Blue for polling
            }

            // Hide start buttons, show stop
            this._startPollingItem.visible = false;
            this._startEbpfItem.visible = false;
            this._stopItem.visible = true;
        } else {
            this._statusItem.label.text = 'Daemon: Stopped';
            this._statusItem.label.style = 'color: #F44336;';
            this._modeItem.label.text = 'Mode: Not Running';
            this._modeItem.label.style = 'color: #888;';

            // Show start buttons, hide stop
            this._startPollingItem.visible = true;
            this._startEbpfItem.visible = true;
            this._stopItem.visible = false;
        }
    }

    _updateAgents() {
        // Clear existing items
        this._agentsSection.removeAll();

        if (!this._daemonRunning) {
            let noAgents = new PopupMenu.PopupMenuItem('Daemon not running');
            noAgents.sensitive = false;
            this._agentsSection.addMenuItem(noAgents);
            return;
        }

        // Read agents from daemon (via shepherd CLI for now)
        try {
            let [success, stdout, stderr, exitCode] = GLib.spawn_command_line_sync(
                'shepherd status --json'
            );

            if (success && exitCode === 0) {
                // Parse JSON response
                // For now, show placeholder
            }
        } catch (e) {
            // Ignore errors
        }

        // Mock data for now - will be replaced with real daemon communication
        this._agents = this._getMockAgents();

        if (this._agents.length === 0) {
            let noAgents = new PopupMenu.PopupMenuItem('No active agents');
            noAgents.sensitive = false;
            noAgents.label.style = 'color: #888; font-style: italic;';
            this._agentsSection.addMenuItem(noAgents);
            return;
        }

        for (let agent of this._agents) {
            let item = this._createAgentItem(agent);
            this._agentsSection.addMenuItem(item);
        }
    }

    _getMockAgents() {
        // Read from /tmp/claude-shepherd-agents.json if it exists
        try {
            let file = Gio.File.new_for_path('/tmp/claude-shepherd-agents.json');
            if (file.query_exists(null)) {
                let [success, contents] = file.load_contents(null);
                if (success) {
                    return JSON.parse(new TextDecoder().decode(contents));
                }
            }
        } catch (e) {
            // Ignore
        }
        return [];
    }

    _createAgentItem(agent) {
        let item = new PopupMenu.PopupBaseMenuItem();

        let box = new St.BoxLayout({
            vertical: true,
            style_class: 'claude-agent-item',
        });

        // Top row: PID and status
        let topRow = new St.BoxLayout({ vertical: false });

        let statusDot = new St.Label({
            text: '●',
            style: `color: ${STATUS_COLORS[agent.status] || '#888'}; margin-right: 8px;`,
        });
        topRow.add_child(statusDot);

        let pidLabel = new St.Label({
            text: `PID ${agent.pid}`,
            style: 'font-weight: bold;',
        });
        topRow.add_child(pidLabel);

        let statusLabel = new St.Label({
            text: ` - ${agent.status}`,
            style: 'color: #888;',
        });
        topRow.add_child(statusLabel);

        box.add_child(topRow);

        // Task description
        let taskLabel = new St.Label({
            text: agent.task || 'No task description',
            style: 'font-size: 11px; color: #aaa; margin-left: 16px;',
        });
        box.add_child(taskLabel);

        // Working directory
        let dirLabel = new St.Label({
            text: agent.working_dir || '',
            style: 'font-size: 10px; color: #666; margin-left: 16px;',
        });
        box.add_child(dirLabel);

        item.add_child(box);

        // Add submenu for agent actions
        item.connect('activate', () => {
            this._showAgentMenu(agent);
        });

        return item;
    }

    _updatePermissions() {
        this._permissionsSection.removeAll();

        if (!this._daemonRunning) {
            return;
        }

        // Mock data - will be replaced with real daemon communication
        this._pendingPermissions = this._getMockPermissions();

        if (this._pendingPermissions.length === 0) {
            let noPerm = new PopupMenu.PopupMenuItem('No pending permissions');
            noPerm.sensitive = false;
            noPerm.label.style = 'color: #888; font-style: italic;';
            this._permissionsSection.addMenuItem(noPerm);
            return;
        }

        for (let perm of this._pendingPermissions) {
            let item = this._createPermissionItem(perm);
            this._permissionsSection.addMenuItem(item);
        }
    }

    _getMockPermissions() {
        try {
            let file = Gio.File.new_for_path('/tmp/claude-shepherd-permissions.json');
            if (file.query_exists(null)) {
                let [success, contents] = file.load_contents(null);
                if (success) {
                    return JSON.parse(new TextDecoder().decode(contents));
                }
            }
        } catch (e) {
            // Ignore
        }
        return [];
    }

    _createPermissionItem(perm) {
        let item = new PopupMenu.PopupBaseMenuItem();

        let box = new St.BoxLayout({ vertical: true });

        // Command
        let cmdLabel = new St.Label({
            text: `${perm.command} ${perm.args || ''}`,
            style: 'font-family: monospace; color: #FF9800;',
        });
        box.add_child(cmdLabel);

        // Reason
        let reasonLabel = new St.Label({
            text: perm.reason || 'Permission required',
            style: 'font-size: 11px; color: #888;',
        });
        box.add_child(reasonLabel);

        // Buttons
        let buttonBox = new St.BoxLayout({
            vertical: false,
            style: 'margin-top: 4px;',
        });

        let approveBtn = new St.Button({
            label: 'Approve',
            style_class: 'claude-approve-btn',
            style: 'background: #4CAF50; color: white; padding: 2px 8px; margin-right: 8px;',
        });
        approveBtn.connect('clicked', () => {
            this._approvePermission(perm.id);
        });
        buttonBox.add_child(approveBtn);

        let denyBtn = new St.Button({
            label: 'Deny',
            style_class: 'claude-deny-btn',
            style: 'background: #F44336; color: white; padding: 2px 8px;',
        });
        denyBtn.connect('clicked', () => {
            this._denyPermission(perm.id);
        });
        buttonBox.add_child(denyBtn);

        box.add_child(buttonBox);

        item.add_child(box);
        item.reactive = false;

        return item;
    }

    _updateIcon() {
        // Update icon based on state
        let hasWaiting = this._pendingPermissions.length > 0;
        let hasActive = this._agents.some(a => a.status === 'running');

        if (hasWaiting) {
            this._icon.icon_name = 'dialog-warning-symbolic';
            this._icon.style = 'color: #FF9800;';
        } else if (hasActive) {
            this._icon.icon_name = 'media-playback-start-symbolic';
            this._icon.style = 'color: #4CAF50;';
        } else if (this._daemonRunning) {
            this._icon.icon_name = 'system-run-symbolic';
            this._icon.style = '';
        } else {
            this._icon.icon_name = 'system-shutdown-symbolic';
            this._icon.style = 'color: #888;';
        }
    }

    _showAgentMenu(agent) {
        // Show dialog with agent options
        this._notify('Agent Actions', `PID ${agent.pid}: ${agent.task}\n\nUse 'shepherd' CLI for full control.`);
    }

    _showQueueDialog() {
        // For now, show notification with instructions
        this._notify('Queue Task', 'Use terminal:\n  shepherd queue "your task description"');
    }

    _showCommandDialog() {
        // Show dialog to send command to active agent
        this._notify('Send Command', 'Use terminal:\n  shepherd response "trigger" "response"');
    }

    _approveAll() {
        try {
            GLib.spawn_command_line_async('shepherd approve-all');
            this._notify('Approved', 'All pending permissions approved');
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, () => {
                this._refresh();
                return GLib.SOURCE_REMOVE;
            });
        } catch (e) {
            this._notify('Error', `Failed to approve: ${e.message}`);
        }
    }

    _approvePermission(id) {
        try {
            GLib.spawn_command_line_async(`shepherd approve ${id}`);
            this._notify('Approved', `Permission #${id} approved`);
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, () => {
                this._refresh();
                return GLib.SOURCE_REMOVE;
            });
        } catch (e) {
            this._notify('Error', `Failed to approve: ${e.message}`);
        }
    }

    _denyPermission(id) {
        try {
            GLib.spawn_command_line_async(`shepherd deny ${id}`);
            this._notify('Denied', `Permission #${id} denied`);
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, () => {
                this._refresh();
                return GLib.SOURCE_REMOVE;
            });
        } catch (e) {
            this._notify('Error', `Failed to deny: ${e.message}`);
        }
    }

    _startDaemon(mode) {
        try {
            if (mode === 'ebpf') {
                // eBPF mode requires root - use pkexec
                GLib.spawn_command_line_async('pkexec claude-shepherd-ebpf -d');
                this._notify('Daemon', 'Starting eBPF daemon (requires authentication)...');
            } else {
                // Polling mode - no root needed
                GLib.spawn_command_line_async('claude-shepherd -d');
                this._notify('Daemon', 'Starting polling daemon...');
            }
        } catch (e) {
            this._notify('Error', `Failed to start daemon: ${e.message}`);
        }

        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1500, () => {
            this._refresh();
            return GLib.SOURCE_REMOVE;
        });
    }

    _stopDaemon() {
        try {
            let [success, contents] = Gio.File.new_for_path(PID_FILE).load_contents(null);
            if (success) {
                let pid = new TextDecoder().decode(contents).trim();
                // Use pkexec if it was running as root (eBPF mode)
                if (this._daemonMode === 'ebpf') {
                    GLib.spawn_command_line_async(`pkexec kill ${pid}`);
                } else {
                    GLib.spawn_command_line_async(`kill ${pid}`);
                }
                this._notify('Daemon', 'Stopping daemon...');
            }
        } catch (e) {
            this._notify('Error', `Failed to stop daemon: ${e.message}`);
        }

        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1000, () => {
            this._refresh();
            return GLib.SOURCE_REMOVE;
        });
    }

    _openLogs() {
        try {
            GLib.spawn_command_line_async('gnome-terminal -- tail -f /tmp/claude-shepherd.log');
        } catch (e) {
            // Try xterm as fallback
            try {
                GLib.spawn_command_line_async('xterm -e "tail -f /tmp/claude-shepherd.log"');
            } catch (e2) {
                this._notify('Error', 'Could not open terminal');
            }
        }
    }

    _notify(title, body) {
        let source = new MessageTray.Source({
            title: 'Claude Shepherd',
            iconName: 'system-run-symbolic',
        });
        Main.messageTray.add(source);

        let notification = new MessageTray.Notification({
            source: source,
            title: title,
            body: body,
        });
        source.addNotification(notification);
    }

    destroy() {
        this._stopRefresh();
        super.destroy();
    }
});

export default class ClaudeShepherdExtension {
    constructor() {
        this._indicator = null;
    }

    enable() {
        this._indicator = new ClaudeShepherdIndicator();
        Main.panel.addToStatusArea('claude-shepherd', this._indicator);
    }

    disable() {
        if (this._indicator) {
            this._indicator.destroy();
            this._indicator = null;
        }
    }
}
