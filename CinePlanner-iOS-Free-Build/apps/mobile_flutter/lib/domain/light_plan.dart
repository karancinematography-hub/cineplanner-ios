import 'lighting_plan.dart';
import 'production.dart';

enum LightPlanCreation { scene, shot, take }

const lightNumberKey = 'light_plan_number';
const lightNumberMaxLength = 80;
final _digits = RegExp(r'^[0-9]+$');

BigInt? parseLightNumber(String? text) =>
    text != null &&
        text.length <= lightNumberMaxLength &&
        _digits.hasMatch(text)
    ? BigInt.tryParse(text)
    : null;

bool isLightNumberedKind(EntityKind kind) =>
    kind.index >= EntityKind.scene.index;

String? lightRecordNumber(ProductionRecord? record) {
  if (record == null || !isLightNumberedKind(record.kind)) return null;
  final saved = record.data[lightNumberKey];
  if (saved is String && parseLightNumber(saved) != null) return saved;

  final title = record.title.trim();
  final details = record.data['details'] as Map?;
  final detail = details?[record.kind == EntityKind.take ? 'slate' : 'number'];
  final oldLabel = record.data.containsKey('light_plan_label');
  if (oldLabel && parseLightNumber(title) != null) return title;
  if (detail is String && parseLightNumber(detail.trim()) != null) {
    return detail.trim();
  }
  return parseLightNumber(title) == null ? null : title;
}

int compareLightRecords(ProductionRecord left, ProductionRecord right) {
  final a = parseLightNumber(lightRecordNumber(left));
  final b = parseLightNumber(lightRecordNumber(right));
  if (a != null && b == null) return -1;
  if (a == null && b != null) return 1;
  final numberOrder = a?.compareTo(b!) ?? 0;
  if (numberOrder != 0) return numberOrder;
  final timeOrder = left.createdAt.compareTo(right.createdAt);
  return timeOrder == 0 ? left.id.compareTo(right.id) : timeOrder;
}

LightingPlan readLightCanvas(ProductionRecord? record) {
  final data = record?.data['lighting_plan'];
  return data == null
      ? LightingPlan([])
      : LightingPlan.fromJson(Map<String, dynamic>.from(data as Map));
}
