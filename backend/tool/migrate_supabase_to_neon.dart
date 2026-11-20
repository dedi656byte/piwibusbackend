import 'dart:io';

import '../lib/src/state_persistence.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stdout.writeln('========================================================');
    stdout.writeln('Usage:');
    stdout.writeln('  dart run tool/migrate_supabase_to_neon.dart "<URL_SUPABASE>" "<URL_NEON>"');
    stdout.writeln('========================================================');
    exit(1);
  }

  final supabaseUrl = args[0].trim();
  final neonUrl = args[1].trim();

  stdout.writeln('=== Migration Supabase -> Neon ===\n');

  stdout.writeln('1. Connexion a Supabase et lecture des donnees...');
  late final PostgresStatePersistence supabase;
  try {
    supabase = await PostgresStatePersistence.open(supabaseUrl);
  } catch (e) {
    stderr.writeln('Erreur de connexion a Supabase: $e');
    exit(1);
  }

  final state = await supabase.loadState();
  if (state == null) {
    stderr.writeln('Aucun etat trouve sur Supabase.');
    await supabase.close();
    exit(1);
  }

  final users = (state['users'] as List?) ?? const [];
  final reports = (state['reports'] as List?) ?? const [];
  final pushTokens = (state['pushTokens'] as List?) ?? const [];
  final activity = (state['activity'] as List?) ?? const [];
  final sessions = (state['sessions'] as Map?) ?? const {};

  stdout.writeln('Donnees trouvees sur Supabase :');
  stdout.writeln('  • Utilisateurs : ${users.length}');
  stdout.writeln('  • Sessions     : ${sessions.length}');
  stdout.writeln('  • Signalements : ${reports.length}');
  stdout.writeln('  • Tokens push  : ${pushTokens.length}');
  stdout.writeln('  • Activites    : ${activity.length}');

  stdout.writeln('\n2. Connexion a Neon et creation automatique du schema...');
  late final PostgresStatePersistence neon;
  try {
    neon = await PostgresStatePersistence.open(neonUrl);
  } catch (e) {
    stderr.writeln('Erreur de connexion a Neon: $e');
    await supabase.close();
    exit(1);
  }

  stdout.writeln('3. Importation des donnees dans Neon...');
  try {
    await neon.saveState(state);
    stdout.writeln('\n🎉 Migration terminee avec succes !');
    stdout.writeln('Toutes vos donnees ont ete transferees dans Neon.');
  } catch (e, stack) {
    stderr.writeln('Erreur lors de l\'ecriture dans Neon: $e\n$stack');
  } finally {
    await supabase.close();
    await neon.close();
  }
}
