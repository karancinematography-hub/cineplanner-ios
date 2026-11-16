import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract final class CineTheme {
  static const ink = Color(0xff171814);
  static const charcoal = Color(0xff2e332d);
  static const olive = Color(0xff788373);
  static const ivory = Color(0xfff5f3ee);
  static const chalk = Color(0xffffffff);
  static const stone = Color(0xffe2ded5);
  static const hairline = Color(0xffc7c7c0);
  static const fontFamily = 'Noto Sans';

  static const compactWidth = 600.0;
  static const tabletWidth = 920.0;
  static const tabletHeight = 540.0;
  static const touch = 48.0;
  static const mediumGlyph = 20.0;
  static const radius = 10.0;
  static const gutter = 16.0;
  static const wideGutter = 24.0;
  static const cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(radius)),
    side: BorderSide(color: hairline),
  );

  static BoxDecoration panel([Color fill = chalk]) => BoxDecoration(
    color: fill,
    border: Border.all(color: hairline),
    borderRadius: BorderRadius.circular(radius),
  );

  static final data = ThemeData(
    useMaterial3: true,
    fontFamily: fontFamily,
    scaffoldBackgroundColor: ivory,
    colorScheme: const ColorScheme.light(
      primary: charcoal,
      onPrimary: chalk,
      primaryContainer: stone,
      onPrimaryContainer: ink,
      secondary: olive,
      onSecondary: ink,
      secondaryContainer: stone,
      onSecondaryContainer: ink,
      surface: chalk,
      onSurface: ink,
      onSurfaceVariant: charcoal,
      surfaceContainerLowest: chalk,
      surfaceContainerLow: ivory,
      surfaceContainer: ivory,
      surfaceContainerHigh: stone,
      surfaceContainerHighest: stone,
      outline: olive,
      outlineVariant: hairline,
      surfaceTint: Colors.transparent,
    ),
    appBarTheme: const AppBarThemeData(
      backgroundColor: ivory,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleSpacing: gutter,
      systemOverlayStyle: SystemUiOverlayStyle.dark,
    ),
    cardTheme: const CardThemeData(
      color: chalk,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: cardShape,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: chalk,
      shape: cardShape,
      elevation: 2,
    ),
    popupMenuTheme: const PopupMenuThemeData(color: chalk, shape: cardShape),
    inputDecorationTheme: const InputDecorationThemeData(
      filled: true,
      fillColor: ivory,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(radius)),
      ),
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: olive),
        borderRadius: BorderRadius.all(Radius.circular(radius)),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: charcoal, width: 2),
        borderRadius: BorderRadius.all(Radius.circular(radius)),
      ),
      helperMaxLines: 3,
      errorMaxLines: 3,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(touch, touch),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(radius)),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(touch, touch),
        focusColor: stone,
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: charcoal,
      foregroundColor: chalk,
      elevation: 1,
    ),
    dividerTheme: const DividerThemeData(color: hairline, thickness: 1),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: charcoal,
      contentTextStyle: TextStyle(color: chalk),
    ),
  );
}

/// Gives list and form routes a shared reading width and safe horizontal edges.
class CinePage extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const CinePage({super.key, required this.child, this.maxWidth = 1120});

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: SizedBox(width: double.infinity, child: child),
      ),
    ),
  );
}

class CineFields extends StatelessWidget {
  final List<Widget> fields;

  const CineFields({super.key, required this.fields});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final width = bounds.maxWidth >= 720
          ? (bounds.maxWidth - CineTheme.gutter) / 2
          : bounds.maxWidth;
      return Wrap(
        spacing: CineTheme.gutter,
        children: [
          for (final field in fields) SizedBox(width: width, child: field),
        ],
      );
    },
  );
}
