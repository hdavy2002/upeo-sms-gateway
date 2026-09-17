import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/app_config.dart';
import '../../services/api_client.dart';
import '../../state/providers.dart';

/// Reusable editor for the gateway configuration, used by both Setup and
/// Settings. Includes Save and Test Connection (a signed heartbeat handshake).
///
/// Renders as a non-scrolling [Column]; the parent screen supplies the scroll
/// view, so the Save / Test Connection buttons are always reachable.
class ConfigForm extends ConsumerStatefulWidget {
  const ConfigForm({super.key, this.onSaved});

  /// Called after a successful save (e.g. to pop the setup flow).
  final VoidCallback? onSaved;

  @override
  ConsumerState<ConfigForm> createState() => _ConfigFormState();
}

class _ConfigFormState extends ConsumerState<ConfigForm> {
  final _formKey = GlobalKey<FormState>();
  final _urlCtrl = TextEditingController();
  final _deviceCtrl = TextEditingController();
  final _secretCtrl = TextEditingController();
  final _allowlistCtrl = TextEditingController();
  final _accountCtrl = TextEditingController();
  final _retentionCtrl = TextEditingController();

  bool _secretVisible = false;
  bool _loaded = false;
  bool _busy = false;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _deviceCtrl.dispose();
    _secretCtrl.dispose();
    _allowlistCtrl.dispose();
    _accountCtrl.dispose();
    _retentionCtrl.dispose();
    super.dispose();
  }

  void _hydrate(AppConfig cfg) {
    if (_loaded) return;
    _loaded = true;
    _urlCtrl.text = cfg.apiBaseUrl;
    _deviceCtrl.text = cfg.deviceId;
    _secretCtrl.text = cfg.secretKey;
    _allowlistCtrl.text = cfg.allowlist.join(', ');
    _accountCtrl.text = cfg.accountSuffix;
    _retentionCtrl.text = '${cfg.retentionDays}';
  }

  AppConfig _collect() {
    final allowlist = _allowlistCtrl.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return AppConfig(
      apiBaseUrl: _urlCtrl.text.trim(),
      deviceId: _deviceCtrl.text.trim(),
      secretKey: _secretCtrl.text,
      allowlist: allowlist,
      accountSuffix: _accountCtrl.text.trim(),
      retentionDays: int.tryParse(_retentionCtrl.text.trim()) ?? 14,
      allowInsecureHttp: false,
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await ref.read(configControllerProvider.notifier).save(_collect());
      if (mounted) {
        _snack('Configuration saved');
        widget.onSaved?.call();
      }
    } catch (_) {
      if (mounted) _snack('Could not save configuration. Please try again.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      // Test only the values on screen. Do not save/start SMS forwarding as a
      // side effect of the operator testing credentials.
      final res = await ApiClient(_collect()).sendHeartbeat({'test': true});
      if (!mounted) return;
      final ok = res.outcome == SendOutcome.success;
      _snack(
        ok ? 'Staging heartbeat accepted — no SMS sent' : 'Test failed: ${res.detail}',
        error: !ok,
      );
    } catch (_) {
      if (mounted) _snack('Heartbeat failed. Please try again.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Generate a strong random secret. You must register the SAME value on the
  /// backend for this Device ID (see the help text / README).
  void _generateSecret() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    setState(() {
      _secretCtrl.text = base64Url.encode(bytes);
      _secretVisible = false;
    });
    _snack('Secret generated — register the same value for this staging device');
  }

  void _snack(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cfgAsync = ref.watch(configControllerProvider);
    return cfgAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Failed to load config: $e'),
      ),
      data: (cfg) {
        _hydrate(cfg);
        return Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Staging only · HDFC payment SMS · Sideload companion',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _urlCtrl,
                decoration: const InputDecoration(
                  labelText: 'AvaTOK staging Worker base URL',
                  hintText: 'https://api-staging.avatok.ai',
                  helperText: 'Only the AvaTOK staging HTTPS origin is accepted.',
                  helperMaxLines: 2,
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                validator: (v) => AppConfig.validateBaseUrl((v ?? '').trim()),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _deviceCtrl,
                decoration: const InputDecoration(
                  labelText: 'Device ID',
                  hintText: 'AVATOK_HDFC_STAGING_01',
                  helperText:
                      'Must match this phone’s registered AvaTOK staging device ID.',
                  helperMaxLines: 3,
                  border: OutlineInputBorder(),
                ),
                validator: (v) => AppConfig.validateDeviceId((v ?? '').trim()),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _secretCtrl,
                obscureText: !_secretVisible,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Device secret key (HMAC)',
                  helperText:
                      'A shared secret you generate, registered in staging '
                      'for this Device ID. Tap the key icon to generate one.',
                  helperMaxLines: 3,
                  border: const OutlineInputBorder(),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Generate strong secret',
                        icon: const Icon(Icons.key),
                        onPressed: _busy ? null : _generateSecret,
                      ),
                      IconButton(
                        tooltip: _secretVisible ? 'Hide' : 'Show',
                        icon: Icon(_secretVisible
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () =>
                            setState(() => _secretVisible = !_secretVisible),
                      ),
                    ],
                  ),
                ),
                validator: (v) => AppConfig.validateSecret(v ?? ''),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _allowlistCtrl,
                decoration: const InputDecoration(
                  labelText: 'HDFC sender allowlist (comma-separated)',
                  helperText:
                      'Exact bank headers, e.g. HDFCBK, HDFCBN. '
                      'DLT routing prefixes such as AD- are supported.',
                  helperMaxLines: 3,
                  border: OutlineInputBorder(),
                ),
                validator: (v) => AppConfig.validateAllowlist(
                    (v ?? '').split(',').map((s) => s.trim()).toList()),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _accountCtrl,
                decoration: const InputDecoration(
                  labelText: 'HDFC account suffix (last 4 digits)',
                  helperText: 'Only credit/received alerts naming this account are queued. OTPs are ignored.',
                  helperMaxLines: 3,
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                validator: (v) => AppConfig.validateAccountSuffix((v ?? '').trim()),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _retentionCtrl,
                decoration: const InputDecoration(
                  labelText: 'Retention window (days)',
                  helperText: 'Synced messages are auto-purged after this many days.',
                  helperMaxLines: 2,
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                validator: (v) {
                  final days = int.tryParse((v ?? '').trim());
                  return days != null && days >= 3 && days <= 90
                      ? null : 'Choose 3–90 days';
                },
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _save,
                      icon: const Icon(Icons.save),
                      label: const Text('Save'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _testConnection,
                      icon: const Icon(Icons.wifi_tethering),
                      label: const Text('Test heartbeat'),
                    ),
                  ),
                ],
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}
