import '../domain/lighting_plan.dart';

String _xml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// Vector export retains metres in its viewBox. No external URLs or scripts.
String exportPlanSvg(LightingPlan plan) {
  final bounds = planBounds(plan);
  final left = bounds.left,
      top = bounds.top,
      right = bounds.right,
      bottom = bounds.bottom;
  final svg = StringBuffer(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="$left $top ${right - left} ${bottom - top}" width="1200" height="900">',
  );
  svg.write(
    '<rect x="$left" y="$top" width="${right - left}" height="${bottom - top}" fill="white"/>',
  );
  for (final stroke in plan.strokes) {
    // Use an opaque ink color for legibility in print.
    final color = (stroke.color & 0xffffff).toRadixString(16).padLeft(6, '0');
    svg.write(
      '<polyline points="${stroke.points.map((p) => '${p.x},${p.y}').join(' ')}" fill="none" stroke="#$color" stroke-width="${stroke.width}" stroke-linecap="round" stroke-linejoin="round"/>',
    );
  }
  for (final o in plan.objects) {
    final cx = o.x + o.width / 2, cy = o.y + o.height / 2;
    svg.write(
      '<g transform="translate($cx $cy) rotate(${o.heading % 360})" stroke="#173f43" stroke-width="0.035" fill="none">',
    );
    switch (o.symbol) {
      case SymbolKind.actor:
      case SymbolKind.ellipse:
        svg.write(
          '<ellipse cx="0" cy="0" rx="${o.width / 2}" ry="${o.height / 2}"/>',
        );
      case SymbolKind.arrow:
        svg.write(
          '<path d="M ${-o.width / 2} 0 L ${o.width / 2} 0 M ${o.width / 2 - 0.25} -0.2 L ${o.width / 2} 0 L ${o.width / 2 - 0.25} 0.2"/>',
        );
      case SymbolKind.text:
        break;
      case SymbolKind.line:
      case SymbolKind.dimension:
      case SymbolKind.polyline:
        svg.write(
          '<path d="M ${-o.width / 2} ${-o.height / 2} L ${o.width / 2} ${o.height / 2}"/>',
        );
      case SymbolKind.lightCone:
        svg.write(
          '<path d="M ${-o.width / 2} 0 L ${o.width / 2} ${-o.height / 2} L ${o.width / 2} ${o.height / 2} Z" fill="#ffd98a" fill-opacity="0.35"/>',
        );
      case SymbolKind.wall:
        svg.write(
          '<rect x="${-o.width / 2}" y="${-o.height / 2}" width="${o.width}" height="${o.height}" fill="#bcc7c7"/>',
        );
      case SymbolKind.window:
      case SymbolKind.door:
        svg.write(
          '<rect x="${-o.width / 2}" y="${-o.height / 2}" width="${o.width}" height="${o.height}"/><path d="M ${-o.width / 2} 0 L ${o.width / 2} 0"/>',
        );
      case SymbolKind.fresnel:
        svg.write(
          '<ellipse cx="0" cy="0" rx="${o.width / 2}" ry="${o.height / 2}"/><path d="M 0 ${-o.height / 2} L 0 ${o.height / 2}"/>',
        );
      default:
        svg.write(
          '<rect x="${-o.width / 2}" y="${-o.height / 2}" width="${o.width}" height="${o.height}" rx="0.05"/>',
        );
        if (o.symbol == SymbolKind.camera) {
          svg.write(
            '<path d="M ${o.width / 2} -0.15 L ${o.width / 2 + 0.2} -0.3 L ${o.width / 2 + 0.2} 0.3 L ${o.width / 2} 0.15"/>',
          );
        }
    }
    final label = o.displayLabel;
    svg.write(
      '<text x="0" y="${o.height / 2 + 0.28}" text-anchor="middle" font-family="Helvetica" font-size="0.2" fill="#162a2c" stroke="none">',
    );
    if (label.length <= 24) {
      svg.write(_xml(label));
    } else {
      for (var start = 0; start < label.length; start += 24) {
        final end = start + 24 < label.length ? start + 24 : label.length;
        svg.write(
          '<tspan x="0" y="${o.height / 2 + 0.28 + (start ~/ 24) * 0.25}">${_xml(label.substring(start, end))}</tspan>',
        );
      }
    }
    svg.write('</text></g>');
  }
  svg.write('</svg>');
  return svg.toString();
}
