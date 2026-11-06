// SPDX-License-Identifier: GPL-3.0-or-later
// The few building blocks every screen uses: RevisionWorx's status sentence and chips, one primary action, sections,
// banners that say plainly what's wrong, and empty states that say what to do next.

import 'package:fieldworx_core/fieldworx_core.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/theme.dart';
import 'fx_icon.dart';

/// Lifecycle state -> tone, as RevisionWorx colours its chips (gui/qt/theme.py STATE_TONES).
Tone stateTone(String state) => switch (state) {
      'released' => Tone.ok,
      'in_review' => Tone.warn,
      'approved' => Tone.info,
      'obsolete' => Tone.danger,
      _ => Tone.neutral,
    };

Tone outcomeTone(String outcome) => switch (outcome) {
      'pass' || 'done' => Tone.ok,
      'fail' => Tone.danger,
      'conflict' || 'photo-missing' || 'incomplete' => Tone.warn,
      'na' => Tone.neutral,
      _ => Tone.neutral,
    };

String outcomeName(String outcome) => switch (outcome) {
      'pass' => 'Pass',
      'fail' => 'Fail',
      'na' => 'N/A',
      'done' => 'Done',
      'open' => 'Open',
      'conflict' => 'Conflict',
      'photo-missing' => 'Photo needed',
      'incomplete' => 'Incomplete',
      _ => outcome,
    };

/// "FRM-200 rev B · Released", RevisionWorx's status sentence.
String revisionSentence(Revision r) {
  final d = r.document;
  return '${d.label} rev ${r.label.isEmpty ? '?' : r.label}${r.stateName.isEmpty ? '' : ' · ${r.stateName}'}';
}

String shortDate(String iso) => iso.length >= 10 ? iso.substring(0, 10) : iso;
String shortTime(String iso) => iso.length >= 16 ? '${iso.substring(0, 10)} ${iso.substring(11, 16)}' : iso;

class StatusChip extends StatelessWidget {
  const StatusChip(this.text, {super.key, this.tone = Tone.neutral, this.icon});
  final String text;
  final Tone tone;
  final String? icon;

  @override
  Widget build(BuildContext context) {
    final fx = context.fx;
    final fg = fx.toneFg(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: fx.toneBg(tone),
        borderRadius: BorderRadius.circular(999),
        border: fx.name == 'high_contrast' ? Border.all(color: fg) : null,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[FxIcon(icon!, size: 14, color: fg, accent: fg), const SizedBox(width: 4)],
        Flexible(
          child: Text(text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: fg, fontSize: 12.5, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

class NoticeBanner extends StatelessWidget {
  const NoticeBanner(this.text, {super.key, this.tone = Tone.warn, this.icon, this.action, this.onAction});
  final String text;
  final Tone tone;
  final String? icon;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final fx = context.fx;
    final fg = fx.toneFg(tone);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: fx.toneBg(tone),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: fx.name == 'high_contrast' ? fg : fx.toneBg(tone)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FxIcon(icon ?? (tone == Tone.danger ? 'error' : tone == Tone.info ? 'info' : 'warning'),
            size: 20, color: fg, accent: fg),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: TextStyle(color: fg, fontSize: 14, height: 1.35))),
        if (action != null)
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(foregroundColor: fg, visualDensity: VisualDensity.compact),
            child: Text(action!),
          ),
      ]),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Row(children: [
          Expanded(
            child: Text(title.toUpperCase(),
                style: TextStyle(
                    color: context.fx.muted, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.6)),
          ),
          if (trailing != null) trailing!,
        ]),
      );
}

/// A card holding rows; rows are separated by thin lines.
class RowsCard extends StatelessWidget {
  const RowsCard({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 16, color: context.fx.border),
            children[i],
          ],
        ]),
      );
}

class KeyValueRow extends StatelessWidget {
  const KeyValueRow(this.label, this.value, {super.key, this.selectable = true});
  final String label, value;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final fx = context.fx;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 118, child: Text(label, style: TextStyle(color: fx.muted, fontSize: 14))),
        Expanded(
          child: selectable
              ? SelectableText(value.isEmpty ? '—' : value, style: TextStyle(color: fx.text, fontSize: 15))
              : Text(value.isEmpty ? '—' : value, style: TextStyle(color: fx.text, fontSize: 15)),
        ),
      ]),
    );
  }
}

/// A tappable row with an icon, a title, a subtitle and optional chips.
class EntityRow extends StatelessWidget {
  const EntityRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle = '',
    this.chips = const [],
    this.trailing,
    this.onTap,
    this.semantics,
  });
  final String icon, title, subtitle;
  final List<Widget> chips;
  final Widget? trailing;
  final VoidCallback? onTap;
  final String? semantics;

  @override
  Widget build(BuildContext context) {
    final fx = context.fx;
    return InkWell(
      onTap: onTap,
      child: Semantics(
        button: onTap != null,
        label: semantics,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: fx.surface2, borderRadius: BorderRadius.circular(10)),
                child: FxIcon(icon, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: fx.text, fontSize: 16, fontWeight: FontWeight.w600)),
                  if (subtitle.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(subtitle,
                          maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: fx.muted, fontSize: 13.5)),
                    ),
                  if (chips.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(spacing: 6, runSpacing: 4, children: chips),
                    ),
                ]),
              ),
              trailing ?? (onTap != null ? FxIcon('chevron_right', size: 20, color: fx.faint) : const SizedBox()),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The header of an entity page: what it is, its number, its title and its state, at a glance.
class StatusBlock extends StatelessWidget {
  const StatusBlock({
    super.key,
    required this.icon,
    required this.kind,
    required this.title,
    this.subtitle = '',
    this.chips = const [],
  });
  final String icon, kind, title, subtitle;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    final fx = context.fx;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: fx.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: fx.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          FxIcon(icon, size: 18, color: fx.muted),
          const SizedBox(width: 6),
          Text(kind.toUpperCase(),
              style: TextStyle(color: fx.muted, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.6)),
        ]),
        const SizedBox(height: 6),
        SelectableText(title, style: TextStyle(color: fx.text, fontSize: 24, fontWeight: FontWeight.w700)),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(color: fx.muted, fontSize: 15.5)),
        ],
        if (chips.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: chips),
        ],
      ]),
    );
  }
}

class PrimaryAction extends StatelessWidget {
  const PrimaryAction(this.label, {super.key, required this.icon, required this.onPressed});
  final String label, icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final fx = context.fx;
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: onPressed,
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          FxIcon(icon, size: 22, color: fx.accentText, accent: fx.accentText),
          const SizedBox(width: 10),
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        ]),
      ),
    );
  }
}

class SecondaryAction extends StatelessWidget {
  const SecondaryAction(this.label, {super.key, required this.icon, required this.onPressed});
  final String label, icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: onPressed,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            FxIcon(icon, size: 20),
            const SizedBox(width: 8),
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
          ]),
        ),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.body = '', this.actions = const []});
  final String icon, title, body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final fx = context.fx;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 36, 28, 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 72,
          height: 72,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: fx.accentSoft, shape: BoxShape.circle),
          child: FxIcon(icon, size: 36),
        ),
        const SizedBox(height: 16),
        Text(title,
            textAlign: TextAlign.center,
            style: TextStyle(color: fx.text, fontSize: 19, fontWeight: FontWeight.w700)),
        if (body.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(body, textAlign: TextAlign.center, style: TextStyle(color: fx.muted, fontSize: 15, height: 1.4)),
        ],
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 20),
          for (final a in actions) Padding(padding: const EdgeInsets.only(bottom: 10), child: a),
        ],
      ]),
    );
  }
}

/// Page body: a scrollable column with the family's spacing.
class PageList extends StatelessWidget {
  const PageList({super.key, required this.children, this.bottom});
  final List<Widget> children;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final list = ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 28), children: children);
    if (bottom == null) return list;
    return Column(children: [
      Expanded(child: list),
      SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(color: context.fx.surface, border: Border(top: BorderSide(color: context.fx.border))),
          child: bottom,
        ),
      ),
    ]);
  }
}

void showMessage(BuildContext context, String text, {bool error = false}) =>
    showMessageOn(ScaffoldMessenger.of(context), text, error: error);

/// For flows whose page may be gone by the time they finish (adding the first package replaces the page that
/// offered it): take the messenger before the first await.
void showMessageOn(ScaffoldMessengerState messenger, String text, {bool error = false}) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(text),
      duration: Duration(seconds: error ? 8 : 4),
      showCloseIcon: error,
    ));
}

/// Explains an exception from the core in words for the person holding the phone.
String explain(Object e) {
  if (e is ArchiveError) return 'This file can’t be used: ${e.message}. Nothing was changed.';
  if (e is StoreError) return e.message;
  if (e is EventError) return '${e.message}.';
  if (e is CatalogError) return 'The package catalog can’t be used: ${e.message}. Nothing was changed.';
  return 'Something went wrong: $e';
}
