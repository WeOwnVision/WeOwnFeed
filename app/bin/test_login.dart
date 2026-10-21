// Measures the sign-in endpoint: dart run bin/test_login.dart <username> <password>
// ignore_for_file: avoid_print
import 'package:weownfeed/services/api_service.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('Usage: dart run bin/test_login.dart <username> <password>');
    return;
  }
  final api = ApiService(logger: print);
  final sw = Stopwatch()..start();
  try {
    final session = await api.login(args[0], args[1]);
    print(
      'Signed in as ${session.user.username} (${session.user.id}) '
      'in ${sw.elapsedMilliseconds} ms',
    );
  } on ApiException catch (e) {
    print('Failed after ${sw.elapsedMilliseconds} ms: $e');
  } finally {
    api.dispose();
  }
}
