Future<void> main(List<String> args) async {
  final int durationSeconds = int.parse(args[0]);
  await Future.delayed(Duration(seconds: durationSeconds));
}
