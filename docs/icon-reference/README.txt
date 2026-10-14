Dokidoki — iOS / macOS 27 图标分层素材

本包含 4 个主体图层：后页纸、前页纸、对话框、ドキドキ。
另附独立蓝紫色底色层。纸张分别提供 opaque 不透明与 frosted 磨砂版本。
每个图层均提供真正的矢量 SVG 和 1024×1024 RGBA PNG；SVG 无内嵌位图、无字体依赖。
字样和对话框从原图轮廓描摹；纸张重新构建连续光滑边缘，并补绘被遮住的部分。
原图为合成 PNG，因此遮挡区是重建内容，并非恢复原始设计文件中的隐藏图层。

一、叠放顺序（从下到上）
00-background       layers/shared/00-background.svg 或 .png
10-paper-back       layers/opaque/10-paper-back.svg 或 .png
20-paper-front      layers/opaque/20-paper-front.svg 或 .png
30-speech-bubble    layers/shared/30-speech-bubble.svg 或 .png
40-dokidoki         layers/shared/40-dokidoki.svg 或 .png

磨砂版：将 10、20 两个纸张文件换成 layers/frosted 下的同名文件。
对话框层包含云朵、爱心和周围短线；ドキドキ层包含全部文字和右侧三条强调线。
每一页的漫画分格与该页纸属于同一层。
所有图层使用相同的 1024×1024 画布、位置与缩放。导入时不要裁剪透明边距。
背景是无透明、未预裁圆角的满幅正方形；主体层背景透明。

二、用于 Icon Composer
将底色层放在最底层，其余按上述顺序导入并保持原位。
可选 SVG；如导入程序对渐变的解释不同，可改用同目录的 PNG。
独立图层没有烘焙跨层投影；请在目标工具中按效果调节深度、阴影和照明。
磨砂 SVG/PNG 表达的是半透明底色、渐变及边缘高光，不包含实时背景模糊或动态折射。
真正的动态磨砂/折射需要在 Icon Composer 中设置材质；以实际工具预览为准。
建议不透明纸保持实心；磨砂纸提高磨砂度、保留中等透光度；字样与对话框保持清晰。
未提供未经验证的 .icon 工程。此包是分层源素材和静态预览，不是最终 Xcode 图标资产。

三、预览文件
composites/opaque.svg 与 frosted.svg：由交付图层确定性合成的可编辑预览，含静态阴影。
composites/opaque.png 与 frosted.png：1024×1024 合成预览。
composites/*-2048.png：2048×2048 合成预览。
previews/01-opaque-ios27-concept.png：实心纸张效果图。
previews/02-frosted-ios27-concept.png：磨砂玻璃纸张效果图。
previews/layer-contact-sheet.png：独立图层检查图。
两张 concept 效果图由 imagegen 基于原图与矢量合成图制作，是风格模拟，并非系统实际渲染截图。
概念效果图的光照/纹理可能与确定性图层预览有细微差异；实际图层以 layers 为准。

四、可重建文件
source/original-reference.png：原始参考图。
source/traced-elements.json：字样与对话框描摹路径数据。
source/build-icon.cjs：生成 SVG/PNG 的源代码。需要 Node.js 和 sharp；运行 node source/build-icon.cjs。
source/render-prompts.json：两张效果图使用的完整提示词。
layer-manifest.json：自定义图层清单与叠放顺序，不是 Apple 原生工程格式。

Apple 官方参考
https://developer.apple.com/icon-composer/
https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer

制作日期：2026-10-14（UTC）
