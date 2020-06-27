// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.6
import 'dart:async';
import 'dart:io' as io;

import 'package:meta/meta.dart';
import 'package:path/path.dart' as pathlib;
import 'package:yaml/yaml.dart';

import 'exceptions.dart';
import 'process.dart';

/// The name of the file that marks the root of a LUCI workspace.
///
/// LUCI targets are addressed relative to this file.
String kWorkspaceFileName = 'luci.yaml';

/// Initializes [workspaceConfiguration] by parsing the `luci.yaml` file.
///
/// This function must be called prior to accessing the workspace.
Future<void> initializeWorkspaceConfiguration() async {
  _workspaceConfiguration = await WorkspaceConfiguration._fromCurrentDirectory();
}

/// The current workspace configuration.
///
/// This getter is available after calling [initializeWorkspaceConfiguration].
/// Accessing it before then results in a [StateError].
WorkspaceConfiguration get workspaceConfiguration {
  if (_workspaceConfiguration == null) {
    throw StateError(
      'Workspace configuration not initialized. Call '
      'initializeWorkspaceConfiguration() prior to accesing it.',
    );
  }
  return _workspaceConfiguration;
}
WorkspaceConfiguration _workspaceConfiguration;

/// Workspace configuration.
@sealed
@immutable
class WorkspaceConfiguration {
  static Future<WorkspaceConfiguration> _fromCurrentDirectory() async {
    final io.Directory workspaceRoot = await findWorkspaceRoot();
    final io.File workspaceFile = io.File(pathlib.join(workspaceRoot.path, kWorkspaceFileName));
    final YamlMap workspaceYaml = loadYaml(await workspaceFile.readAsString());

    return WorkspaceConfiguration._(
      name: workspaceYaml['name'],
      dartSdkPath: await _resolveDartSdkPath(workspaceYaml['dart_sdk_path']),
      configurationFile: workspaceFile,
      rootDirectory: workspaceRoot,
      targetsYaml: workspaceYaml['targets'],
    );
  }

  WorkspaceConfiguration._({
    @required this.name,
    @required this.dartSdkPath,
    @required this.configurationFile,
    @required this.rootDirectory,
    @required this.targetsYaml,
  });

  /// The name of the workspace.
  ///
  /// Useful for debugging and dashboarding.
  final String name;

  /// The path to the Dart SDK.
  ///
  /// This is the directory that contains the `bin/` directory.
  final String dartSdkPath;

  /// The `luci.yaml` file.
  final io.File configurationFile;

  /// The root directory of the workspace.
  final io.Directory rootDirectory;

  /// Build targets parsed from the `luci.yaml` file.
  final YamlMap targetsYaml;

  /// Path to the `dart` executable.
  String get dartExecutable => pathlib.join(dartSdkPath, 'bin', 'dart');
}

Future<String> _resolveDartSdkPath(String configValue) async {
  const String docs =
    'Please specify a correct dart_sdk_path. The value may be the path to a '
    'Dart SDK containing the bin/ directory, or the special value "_ENV_" '
    'that will try to locate it using the DART_SDK_PATH and PATH environment '
    'variables. See README.md for more information.';

  if (configValue == null) {
    throw ToolException(
      'dart_sdk_path is missing in ${await _findWorkspaceConfigFile()}.\n'
      '$docs'
    );
  }

  String dartSdkPathSource;
  io.Directory sdkPath = io.Directory(configValue);

  if (configValue == '_ENV_') {
    if (io.Platform.environment.containsKey('DART_SDK_PATH')) {
      dartSdkPathSource = 'DART_SDK_PATH environment variable';
      sdkPath = io.Directory(io.Platform.environment['DART_SDK_PATH']);
    } else {
      // TODO(yjbanov): implement for Windows.
      // TODO(yjbanov): implement look-up from the Flutter SDK.
      dartSdkPathSource = 'the PATH environment variable';
      final io.File dartBin = io.File(await evalProcess('which', <String>['dart']));
      sdkPath = dartBin.parent.parent;
    }
  } else {
    dartSdkPathSource = 'the ${await _findWorkspaceConfigFile()} file';
    sdkPath = io.Directory(configValue);
  }

  if (!await sdkPath.exists()) {
    throw ToolException(
      'dart_sdk_path "$configValue" specified in $dartSdkPathSource '
      'not found.\n'
      '$docs'
    );
  }

  return sdkPath.absolute.path;
}

io.Directory _workspaceRoot;

/// Finds the `luci.yaml` file.
FutureOr<io.File> _findWorkspaceConfigFile() async {
  return io.File(pathlib.join((await findWorkspaceRoot()).path, kWorkspaceFileName));
}

/// Find the root of the LUCI workspace starting from the current working directory.
///
/// A LUCI workspace root contains a file called "luci.yaml".
FutureOr<io.Directory> findWorkspaceRoot() async {
  if (_workspaceRoot != null) {
    return _workspaceRoot;
  }

  io.Directory directory = io.Directory.current;
  while(!await isWorkspaceRoot(directory)) {
    final io.Directory previousDirectory = directory;
    directory = directory.parent;

    if (directory.path == previousDirectory.path) {
      // Reached file system root.
      throw ToolException(
        'Failed to locate the LUCI workspace from ${io.Directory.current.absolute.path}.\n'
        'Make sure you run luci.dart from within a LUCI workspace. The workspace is identified '
        'by the presence of $kWorkspaceFileName file.',
      );
    }
  }
  return _workspaceRoot = directory.absolute;
}

/// Returns `true` if [directory] is a LUCI workspace root directory.
///
/// A LUCI workspace root contains a file called "luci.yaml".
Future<bool> isWorkspaceRoot(io.Directory directory) async {
  final io.File workspaceFile = await directory.list().firstWhere(
    (io.FileSystemEntity entity) {
      return entity is io.File && pathlib.basename(entity.path) == kWorkspaceFileName;
    },
    orElse: () => null) as io.File;
  return workspaceFile != null;
}

/// Scans all `build.luci.dart` files in the workspace and constructs a complete
/// build graph.
Future<BuildGraph> resolveBuildGraph() async {
  return _BuildGraphResolver().resolve();
}

/// A complete build graph made of targets collected from a workspace.
class BuildGraph {
  BuildGraph._({
    this.targets,
    this.targetsInDependencyOrder,
  });

  final Map<String, WorkspaceTarget> targets;
  final List<WorkspaceTarget> targetsInDependencyOrder;

  /// Serializes this build graph to JSON for other tools.
  ///
  /// This allows other tools to work with the graph without a dependency on
  /// `luci.dart`.
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> buildGraphJson = <String, dynamic>{};
    buildGraphJson['name'] = workspaceConfiguration.name;

    final List<Map<String, dynamic>> targetListJson = <Map<String, dynamic>>[];
    for (final WorkspaceTarget workspaceTarget in targetsInDependencyOrder) {
      targetListJson.add(workspaceTarget.toJson());
    }
    buildGraphJson['targets'] = targetListJson;

    return buildGraphJson;
  }
}

class _BuildGraphResolver {
  /// Maps from target name to target.
  final Map<String, WorkspaceTarget> workspaceTargetIndex = <String, WorkspaceTarget>{};

  /// Targets ordered according to their dependencies.
  final List<WorkspaceTarget> targetsInDependencyOrder = <WorkspaceTarget>[];

  Future<BuildGraph> resolve() async {
    workspaceConfiguration.targetsYaml.forEach((dynamic targetName, dynamic targetConfiguration) {
      _resolveTarget(targetName as String, targetConfiguration as YamlMap);
    });

    if (_cycles.isNotEmpty) {
      final StringBuffer error = StringBuffer('Dependency cycles detected:\n');
      for (List<String> cycle in _cycles) {
        error.writeln('  Cycle: ${cycle.join(' -> ')}');
      }
      throw ToolException(error.toString());
    }

    return BuildGraph._(
      targets: workspaceTargetIndex,
      targetsInDependencyOrder: targetsInDependencyOrder,
    );
  }

  List<String> _traversalStack = <String>[];
  List<List<String>> _cycles = <List<String>>[];

  WorkspaceTarget _resolveTarget(
    String targetName,
    YamlMap targetConfiguration,
  ) {
    if (workspaceTargetIndex.containsKey(targetName)) {
      return workspaceTargetIndex[targetName];
    }

    if (_traversalStack.contains(targetName)) {
      _cycles.add(<String>[
        ..._traversalStack.sublist(_traversalStack.indexOf(targetName)),
        targetName,
      ]);
      return null;
    }

    _traversalStack.add(targetName);

    final List<String> dependencies = targetConfiguration['dependencies']?.cast<String>() ?? const <String>[];
    final List<String> command = targetConfiguration['command'].split(' ');
    final String executable = command.first;
    final List<String> arguments = command.skip(1).toList();

    final WorkspaceTarget target = WorkspaceTarget(
      name: targetName,
      agentProfile: targetConfiguration['agent_profile'],
      executable: executable,
      arguments: arguments,
      workingDirectoryPath: targetConfiguration['working_directory'],
      environment: targetConfiguration['environment'] ?? const <String, String>{},
      dependencies: dependencies
        .map((String dependencyName) => _resolveDependency(dependencyName, targetName))
        // If there's a cycle the dependency resolves to null.
        // We don't stop the resolution process. Instead, we collect all cycles
        // then report them all.
        .where((WorkspaceTarget dependency) => dependency != null)
        .toList(),
    );
    workspaceTargetIndex[targetName] = target;
    targetsInDependencyOrder.add(target);

    _traversalStack.removeLast();
    return target;
  }

  WorkspaceTarget _resolveDependency(String dependencyName, String from) {
    final YamlMap dependencyYaml = workspaceConfiguration.targetsYaml[dependencyName];

    if (dependencyYaml == null) {
      throw ToolException(
        'Build target $dependencyName does not exist.\n'
        'Target $from specified it as its dependency.\n'
        'Possible fixes for this error:\n'
        '* Remove this dependency from $from\n'
        '* Add the missing target "${dependencyName}"'
      );
    }

    return _resolveTarget(dependencyName, dependencyYaml);
  }
}

/// Decorates a [BuildTarget] with workspace information.
@sealed
@immutable
class WorkspaceTarget {
  const WorkspaceTarget({
    @required this.name,
    @required this.agentProfile,
    @required this.executable,
    @required this.arguments,
    @required this.workingDirectoryPath,
    @required this.environment,
    @required this.dependencies,
  });

  /// The name of the target, unique within the workspace.
  final String name;

  /// Name of the agent profile that this target requires.
  final String agentProfile;

  final String executable;

  final List<String> arguments;

  final String workingDirectoryPath;

  /// Additional environment variables used when running this target.
  final Map<String, String> environment;

  /// Targets that this target depends on.
  final List<WorkspaceTarget> dependencies;

  /// Serializes this target to JSON for digestion by the LUCI recipe.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'agentProfile': agentProfile,
      'command': <String>[
        executable,
        ...arguments,
      ],
      if (environment.isNotEmpty)
        'environment' : environment,
      if (dependencies.isNotEmpty)
        'dependencies': dependencies.map((e) => e.name).toList(),
    };
  }
}

Future<void> runSingleTarget(WorkspaceTarget target) async {
  final io.Process targetProcess = await startProcess(
    target.executable,
    target.arguments,
    workingDirectory: target.workingDirectoryPath,
  );

  final int exitCode = await targetProcess.exitCode;

  if (exitCode != 0) {
    throw ToolException('Target ${target.name} failed');
  }
}
