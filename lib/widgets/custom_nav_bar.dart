import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/responsive_utils.dart';

class CustomNavBar extends StatelessWidget {
  final int currentIndex;
  final Function(int) onTap;
  final Color backgroundColor;
  final Color selectedItemColor;
  final Color unselectedItemColor;
  final List<BottomNavigationBarItem> items;

  const CustomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
    this.backgroundColor = Colors.black,
    this.selectedItemColor = Colors.redAccent,
    this.unselectedItemColor = Colors.white60,
  });

  @override
  Widget build(BuildContext context) {
    final navBarHeight = ResponsiveUtils.getNavBarHeight(context);
    final horizontalPadding = ResponsiveUtils.getHorizontalPadding(context);

    return Container(
      height: navBarHeight,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius:
            ResponsiveUtils.isTablet(context) ||
                ResponsiveUtils.isDesktop(context)
            ? const BorderRadius.only(
                topLeft: Radius.circular(24),
                topRight: Radius.circular(24),
              )
            : const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
              ),
        boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 10)],
      ),
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical:
            ResponsiveUtils.isTablet(context) ||
                ResponsiveUtils.isDesktop(context)
            ? 12
            : 10,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: List.generate(items.length, (index) {
          final item = items[index];
          return _buildNavItem(item.icon, item.label ?? '', index, context);
        }),
      ),
    );
  }

  Widget _buildNavItem(
    Widget icon,
    String label,
    int index,
    BuildContext context,
  ) {
    final isSelected = index == currentIndex;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            HapticFeedback.lightImpact();
            onTap(index);
          },
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedScale(
                  scale: isSelected ? 1.1 : 1.0,
                  duration: const Duration(milliseconds: 150),
                  child: IconTheme(
                    data: IconThemeData(
                      color: isSelected
                          ? selectedItemColor
                          : unselectedItemColor,
                      size: ResponsiveUtils.responsive(
                        context,
                        mobile: 24.0,
                        tablet: 26.0,
                        desktop: 28.0,
                      ),
                    ),
                    child: icon,
                  ),
                ),
                SizedBox(
                  height:
                      ResponsiveUtils.isTablet(context) ||
                          ResponsiveUtils.isDesktop(context)
                      ? 6
                      : 4,
                ),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 150),
                  style: TextStyle(
                    color: isSelected ? selectedItemColor : unselectedItemColor,
                    fontSize: ResponsiveUtils.getFontSize(
                      context,
                      mobile: isSelected ? 12.5 : 12,
                    ),
                    fontWeight: isSelected
                        ? FontWeight.w600
                        : FontWeight.normal,
                  ),
                  child: Text(label),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
