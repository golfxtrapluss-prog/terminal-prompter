import 'dart:io';

import 'package:args/command_runner.dart';

import 'console.dart';

/// `tp-agent uninstall` (docs/06 "Avinstallasjon"): stops the service and
/// removes the binary, service files, sudoers entry and configuration.
/// State and audit log in /var/lib/tp-agent are kept unless confirmed or
/// `--purge` is given. The `tp` user is left in place.
final class UninstallCommand extends Command<int> {
  UninstallCommand({
    required this.out,
    required this.err,
    required this.console,
  }) {
    argParser
      ..addFlag(
        'purge',
        negatable: false,
        help: 'Also delete /var/lib/tp-agent (auth state, audit log).',
      )
      ..addFlag('yes', abbr: 'y', negatable: false, help: 'Do not ask.')
      ..addOption(
        'root',
        hide: true,
        defaultsTo: '',
        help: 'Filesystem prefix (tests).',
      );
  }

  final StringSink out;
  final StringSink err;
  final Console console;

  @override
  String get name => 'uninstall';

  @override
  String get description => 'Remove the agent from this server.';

  @override
  Future<int> run() async {
    final args = argResults!;
    final root = args.option('root')!;
    final yes = args.flag('yes');
    if (root.isEmpty &&
        Process.runSync('id', ['-u']).stdout.toString().trim() != '0') {
      err.writeln('Run as root: sudo tp-agent uninstall');
      return 77; // EX_NOPERM
    }
    if (!yes) {
      final a = console.ask(
        'Remove Terminal Prompter from this server? [y/N] ',
      );
      if (a == null || !a.toLowerCase().startsWith('y')) {
        out.writeln('Nothing changed.');
        return 0;
      }
    }
    if (root.isEmpty) {
      if (Directory('/run/systemd/system').existsSync()) {
        Process.runSync('systemctl', ['disable', '--now', 'tp-agent']);
      } else if (File('/etc/init.d/tp-agent').existsSync()) {
        Process.runSync('rc-service', ['tp-agent', 'stop']);
        Process.runSync('rc-update', ['del', 'tp-agent', 'default']);
      }
    }
    final removed = <String>[];
    void remove(String path) {
      final full = '$root$path';
      final type = FileSystemEntity.typeSync(full, followLinks: false);
      if (type == FileSystemEntityType.notFound) return;
      if (type == FileSystemEntityType.directory) {
        Directory(full).deleteSync(recursive: true);
      } else {
        File(full).deleteSync();
      }
      removed.add(path);
    }

    remove('/etc/systemd/system/tp-agent.service');
    remove('/etc/init.d/tp-agent');
    remove('/etc/sudoers.d/tp-agent');
    remove('/etc/tp-agent');
    remove('/usr/local/bin/tp-agent');
    if (root.isEmpty) Process.runSync('systemctl', ['daemon-reload']);

    var purge = args.flag('purge');
    if (!purge && !yes && Directory('$root/var/lib/tp-agent').existsSync()) {
      final a = console.ask(
        'Also delete /var/lib/tp-agent (passkeys, backup codes, audit log)? [y/N] ',
      );
      purge = a != null && a.toLowerCase().startsWith('y');
    }
    if (purge) remove('/var/lib/tp-agent');

    for (final r in removed) {
      out.writeln('removed $r');
    }
    if (!purge && Directory('$root/var/lib/tp-agent').existsSync()) {
      out.writeln('kept /var/lib/tp-agent (audit log and auth state)');
    }
    out.writeln('The "tp" user was kept; remove it with: sudo userdel -r tp');
    return 0;
  }
}
