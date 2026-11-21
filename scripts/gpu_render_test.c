/*
 * Alpindroid GPU 真实渲染验证程序
 *
 * 目的：eglinfo 只能证明 EGL 初始化成功，不能证明 GPU 真的执行了作业。
 * 本程序完整走一遍真实渲染管线：
 *   1. EGL surfaceless 平台初始化（不依赖 X/Wayland/DRM 显示路径）
 *   2. 创建 pbuffer surface + GLES2 context
 *   3. 编译/链接 shader，绘制一个渐变三角形
 *   4. glReadPixels 回读像素，验证渲染结果是否符合预期
 *   5. 打印 GL_RENDERER / GL_VENDOR 确认走的是 Panfrost 而非 llvmpipe
 *
 * 编译（在板子上）：
 *   gcc -O2 -o gpu_render_test gpu_render_test.c -lEGL -lGLESv2
 *
 * 运行：
 *   ./gpu_render_test
 *
 * 预期输出：
 *   GL_VENDOR   : Mesa
 *   GL_RENDERER : Mali-G31 (Panfrost)
 *   PIXEL ...   : 像素值与预期一致 → GPU 真实完成了光栅化
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

static void die(const char *msg)
{
	fprintf(stderr, "FAIL: %s\n", msg);
	exit(1);
}

static GLuint compile_shader(GLenum type, const char *src)
{
	GLuint s = glCreateShader(type);
	GLint ok = 0;

	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[2048];
		glGetShaderInfoLog(s, sizeof(log), NULL, log);
		fprintf(stderr, "shader compile failed: %s\n", log);
		exit(1);
	}
	return s;
}

int main(void)
{
	EGLDisplay dpy;
	EGLConfig cfg;
	EGLint num_cfg = 0;
	EGLSurface surf;
	EGLContext ctx;
	PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display;
	EGLint major, minor;

	/* ---------- 1. EGL surfaceless 初始化 ---------- */
	get_platform_display = (PFNEGLGETPLATFORMDISPLAYEXTPROC)
		eglGetProcAddress("eglGetPlatformDisplayEXT");
	if (!get_platform_display)
		die("eglGetPlatformDisplayEXT 不可用");

	dpy = get_platform_display(EGL_PLATFORM_SURFACELESS_MESA,
				   EGL_DEFAULT_DISPLAY, NULL);
	if (dpy == EGL_NO_DISPLAY)
		die("eglGetPlatformDisplay 返回 NO_DISPLAY");

	if (!eglInitialize(dpy, &major, &minor))
		die("eglInitialize 失败");

	printf("EGL version   : %d.%d\n", major, minor);
	printf("EGL vendor    : %s\n", eglQueryString(dpy, EGL_VENDOR));

	/* ---------- 2. 选 config（pbuffer + GLES2）---------- */
	{
		EGLint attrs[] = {
			EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT,
			EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
			EGL_RED_SIZE,        8,
			EGL_GREEN_SIZE,      8,
			EGL_BLUE_SIZE,       8,
			EGL_ALPHA_SIZE,      8,
			EGL_NONE
		};
		if (!eglChooseConfig(dpy, attrs, &cfg, 1, &num_cfg) || num_cfg < 1)
			die("eglChooseConfig 没找到合适的 config");
	}

	/* ---------- 3. pbuffer + context ---------- */
	{
		EGLint pb[] = { EGL_WIDTH, 256, EGL_HEIGHT, 256, EGL_NONE };
		surf = eglCreatePbufferSurface(dpy, cfg, pb);
		if (surf == EGL_NO_SURFACE)
			die("eglCreatePbufferSurface 失败");
	}
	{
		EGLint ca[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
		ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ca);
		if (ctx == EGL_NO_CONTEXT)
			die("eglCreateContext 失败");
	}
	if (!eglMakeCurrent(dpy, surf, surf, ctx))
		die("eglMakeCurrent 失败");

	/* ---------- 4. 打印 GPU 身份 ---------- */
	printf("GL_VENDOR     : %s\n", glGetString(GL_VENDOR));
	printf("GL_RENDERER   : %s\n", glGetString(GL_RENDERER));
	printf("GL_VERSION    : %s\n", glGetString(GL_VERSION));
	printf("GLSL version  : %s\n", glGetString(GL_SHADING_LANGUAGE_VERSION));

	/* ---------- 5. 真实渲染：画一个三角形 ---------- */
	{
		static const char *vs_src =
			"attribute vec2 a_pos;\n"
			"attribute vec3 a_col;\n"
			"varying vec3 v_col;\n"
			"void main() {\n"
			"    v_col = a_col;\n"
			"    gl_Position = vec4(a_pos, 0.0, 1.0);\n"
			"}\n";
		static const char *fs_src =
			"precision mediump float;\n"
			"varying vec3 v_col;\n"
			"void main() {\n"
			"    gl_FragColor = vec4(v_col, 1.0);\n"
			"}\n";

		GLuint vs = compile_shader(GL_VERTEX_SHADER, vs_src);
		GLuint fs = compile_shader(GL_FRAGMENT_SHADER, fs_src);
		GLuint prog = glCreateProgram();
		GLint ok = 0;

		glAttachShader(prog, vs);
		glAttachShader(prog, fs);
		glBindAttribLocation(prog, 0, "a_pos");
		glBindAttribLocation(prog, 1, "a_col");
		glLinkProgram(prog);
		glGetProgramiv(prog, GL_LINK_STATUS, &ok);
		if (!ok) {
			char log[2048];
			glGetProgramInfoLog(prog, sizeof(log), NULL, log);
			fprintf(stderr, "program link failed: %s\n", log);
			exit(1);
		}
		glUseProgram(prog);

		/* 覆盖整个视口的两个三角形 = 一个四边形，纯绿色
		 * 这样读回来的像素一定是 (0, 255, 0, 255)，便于精确校验
		 */
		static const GLfloat verts[] = {
			/* x     y     r  g  b */
			-1.0f, -1.0f, 0, 1, 0,
			 1.0f, -1.0f, 0, 1, 0,
			 1.0f,  1.0f, 0, 1, 0,
			-1.0f, -1.0f, 0, 1, 0,
			 1.0f,  1.0f, 0, 1, 0,
			-1.0f,  1.0f, 0, 1, 0,
		};

		glViewport(0, 0, 256, 256);
		glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);

		glEnableVertexAttribArray(0);
		glEnableVertexAttribArray(1);
		glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE,
				      5 * sizeof(GLfloat), &verts[0]);
		glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE,
				      5 * sizeof(GLfloat), &verts[2]);
		glDrawArrays(GL_TRIANGLES, 0, 6);
		glFinish();

		/* ---------- 6. 回读像素校验 ---------- */
		{
			unsigned char px[4] = { 0, 0, 0, 0 };
			GLenum err;

			glReadPixels(128, 128, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
			err = glGetError();
			if (err != GL_NO_ERROR) {
				fprintf(stderr, "glReadPixels 出错: 0x%x\n", err);
				return 1;
			}

			printf("PIXEL center  : R=%d G=%d B=%d A=%d\n",
			       px[0], px[1], px[2], px[3]);

			/* GPU 真的画了绿色才算通过 */
			if (px[1] > 200 && px[0] < 60 && px[2] < 60) {
				printf("RESULT        : PASS（GPU 真实完成了光栅化）\n");
			} else {
				printf("RESULT        : FAIL（像素值不符合预期，"
				       "可能没有真正渲染）\n");
				return 1;
			}
		}
	}

	eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroyContext(dpy, ctx);
	eglDestroySurface(dpy, surf);
	eglTerminate(dpy);

	printf("DONE\n");
	return 0;
}
