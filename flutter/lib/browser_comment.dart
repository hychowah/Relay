import 'package:material_ui/material_ui.dart';

/// Drawn by Relay so the agent's comment stays separate from the page it reads.
class BrowserComment extends StatelessWidget {
  const BrowserComment({
    super.key,
    required this.text,
    required this.onDismiss,
  });
  final String text;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) => Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 350,
            maxHeight: size.maxHeight * .4,
          ),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            builder: (context, value, child) => Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(0, 4 * (1 - value)),
                child: child,
              ),
            ),
            child: Semantics(
              container: true,
              liveRegion: true,
              label: 'Relay explanation',
              child: Material(
                elevation: 7,
                color: const Color(0xff20342e),
                shadowColor: const Color(0x66102820),
                borderRadius: BorderRadius.circular(18),
                child: Stack(
                  children: [
                    SingleChildScrollView(
                      primary: false,
                      padding: const EdgeInsets.fromLTRB(16, 13, 42, 14),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.auto_awesome,
                                size: 14,
                                color: Color(0xffb9e8cf),
                              ),
                              SizedBox(width: 6),
                              Text(
                                'Relay',
                                style: TextStyle(
                                  color: Color(0xffb9e8cf),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          SelectableText(
                            text,
                            style: const TextStyle(
                              color: Color(0xfff5faf7),
                              fontSize: 14,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      top: 5,
                      right: 5,
                      child: IconButton(
                        tooltip: 'Dismiss explanation',
                        style: IconButton.styleFrom(
                          minimumSize: const Size.square(30),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          backgroundColor: const Color(0x10ffffff),
                          foregroundColor: const Color(0xffd6e5de),
                          shape: const CircleBorder(),
                        ),
                        onPressed: onDismiss,
                        icon: const Icon(Icons.close, size: 15),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
