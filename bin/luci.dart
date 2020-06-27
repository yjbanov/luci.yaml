// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// The command-line tool used to inspect and run LUCI build targets.

// @dart = 2.6
import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:args/command_runner.dart';

import 'package:luci/src/cleanup.dart';
import 'package:luci/src/exceptions.dart';
import 'package:luci/src/workspace.dart';
import 'package:luci/src/args.dart';

/// The standard JSON encoder used to encode the output of `luci.dart` sub-commands.
const _kJsonEncoder = const JsonEncoder.withIndent('  ');

Future<void> main(List<String> args) async {
  await initializeWorkspaceConfiguration();

  final CommandRunner<bool> runner = CommandRunner<bool>(
    'luci',
    'Run LUCI targets.',
  )
    ..addCommand(TargetsCommand())
    ..addCommand(RunCommand());

  if (args.isEmpty) {
    // Invoked with no arguments. Print usage.
    runner.printUsage();
    io.exit(64); // Exit code 64 indicates a usage error.
  }

  try {
    await runner.run(args);
  } on ToolException catch (error) {
    io.stderr.writeln(error.message);
    io.exitCode = 1;
  } on UsageException catch (error) {
    io.stderr.writeln('$error\n');
    runner.printUsage();
    io.exitCode = 64; // Exit code 64 indicates a usage error.
  } finally {
    await cleanup();
  }

  // Sometimes the Dart VM refuses to quit if there are open "ports" (could be
  // network, open files, processes, isolates, etc). Calling `exit` explicitly
  // is the surest way to quit the process.
  io.exit(io.exitCode);
}

/// Prints available targets to the standard output in JSON format.
class TargetsCommand extends Command<bool> with ArgUtils {
  @override
  String get name => 'targets';

  @override
  String get description => 'Prints the list of all available targets in JSON format.';

  @override
  FutureOr<bool> run() async {
    final BuildGraph buildGraph = await resolveBuildGraph();
    print(_kJsonEncoder.convert(buildGraph.toJson()['targets']));
    return true;
  }
}

/// Runs LUCI targets.
class RunCommand extends Command<bool> with ArgUtils {
  @override
  String get name => 'run';

  @override
  String get description => 'Runs targets.';

  List<String> get targetNames => argResults.rest;

  @override
  FutureOr<bool> run() async {
    final BuildGraph buildGraph = await resolveBuildGraph();
    final Iterable<WorkspaceTarget> availableTargets = buildGraph.targetsInDependencyOrder;

    final Set<String> visited = <String>{};
    final List<WorkspaceTarget> queue = <WorkspaceTarget>[];
    for (final String targetName in targetNames) {
      final WorkspaceTarget target = buildGraph.targets[targetName];
      if (target == null) {
        throw ToolException(
          'Target $targetName not found.\n'
          'Make sure that ${workspaceConfiguration.configurationFile.path} defines this target. Available targets in that file are:\n'
          '${availableTargets.map((WorkspaceTarget target) => target.name).join('\n')}'
        );
      }
      queue.add(target);
      visited.add(target.name);
    }

    while (queue.isNotEmpty) {
      final WorkspaceTarget target = queue.removeLast();
      queue.addAll(target.dependencies);
      print('Running ${target.name}');
      await runSingleTarget(target);
    }

    return true;
  }
}
