import 'entities.dart';

/// Any non-`go` verdict that the user adds anyway is recorded as an override (spec §8.4, Q7). Never blocks (P7).
bool isOverride(Verdict verdict) => verdict != Verdict.go;
