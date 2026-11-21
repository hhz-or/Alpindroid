/*
 * Alpindroid GPU 压力测试
 *
 * 测试 A：单个 EGL Context 连续绘制 N 帧，抽样回读像素校验
 * 测试 B：反复创建/销毁 EGL Context，检查资源泄漏与稳定性
 *
 * 编译：gcc -O2 -o gpu_stress_test gpu_stress_test.c -lEGL -lGLESv2
 * 运行：./gpu_stress_test            # 默认 A=10000 帧, B=100 次
 *       ./gpu_stress_test 1000 50    # 自定义
 *
 * 退出码：0=全部通过，1=失败
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

static PFNEGLGETPLATFORMDISPLAYEXTPROC p_get_platform_display;

static EGLDisplay make_display(void)
{
    EGLDisplay dpy = p_get_platform_display(EGL_PLATFORM_SURFACELESS_MESA,
                                            EGL_DEFAULT_DISPLAY, NULL);
    if (dpy == EGL_NO_DISPLAY) return EGL_NO_DISPLAY;
    if (!eglInitialize(dpy, NULL, NULL)) return EGL_NO_DISPLAY;
    return dpy;
}

static GLuint build_program(void)
{
    static const char *vs_src =
        "attribute vec2 a_pos;\n"
        "attribute vec3 a_col;\n"
        "varying vec3 v_col;\n"
        "void main(){ v_col=a_col; gl_Position=vec4(a_pos,0.0,1.0); }\n";
    static const char *fs_src =
        "precision mediump float;\n"
        "varying vec3 v_col;\n"
        "void main(){ gl_FragColor=vec4(v_col,1.0); }\n";

    const char *srcs[2] = { vs_src, fs_src };
    GLenum types[2] = { GL_VERTEX_SHADER, GL_FRAGMENT_SHADER };
    GLuint sh[2];

    for (int k = 0; k < 2; k++) {
        sh[k] = glCreateShader(types[k]);
        glShaderSource(sh[k], 1, &srcs[k], NULL);
        glCompileShader(sh[k]);
        GLint ok = 0;
        glGetShaderiv(sh[k], GL_COMPILE_STATUS, &ok);
        if (!ok) return 0;
    }

    GLuint prog = glCreateProgram();
    glAttachShader(prog, sh[0]);
    glAttachShader(prog, sh[1]);
    glBindAttribLocation(prog, 0, "a_pos");
    glBindAttribLocation(prog, 1, "a_col");
    glLinkProgram(prog);
    GLint ok = 0;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) return 0;
    return prog;
}

/* 用当前 context 画一帧并回读中心像素；返回 1 表示绿色正确 */
static int draw_one(GLuint prog, int w, int h)
{
    static const GLfloat verts[] = {
        -1.f,-1.f, 0,1,0,
         1.f,-1.f, 0,1,0,
         1.f, 1.f, 0,1,0,
        -1.f,-1.f, 0,1,0,
         1.f, 1.f, 0,1,0,
        -1.f, 1.f, 0,1,0,
    };
    unsigned char px[4] = {0,0,0,0};

    glViewport(0, 0, w, h);
    glClearColor(0.f, 0.f, 0.f, 1.f);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(prog);
    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 5*sizeof(GLfloat), &verts[0]);
    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 5*sizeof(GLfloat), &verts[2]);
    glDrawArrays(GL_TRIANGLES, 0, 6);
    glReadPixels(w/2, h/2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);

    if (glGetError() != GL_NO_ERROR) return 0;
    return (px[1] > 200 && px[0] < 60 && px[2] < 60);
}

int main(int argc, char **argv)
{
    int frames = (argc > 1) ? atoi(argv[1]) : 10000;
    int ctx_loops = (argc > 2) ? atoi(argv[2]) : 100;
    const int W = 256, H = 256;
    time_t t0;

    p_get_platform_display = (PFNEGLGETPLATFORMDISPLAYEXTPROC)
        eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (!p_get_platform_display) { printf("FAIL: no eglGetPlatformDisplayEXT\n"); return 1; }

    printf("=== GPU stress test ===\n");
    printf("frames=%d ctx_loops=%d\n", frames, ctx_loops);

    /* ---------------- 测试 A：单 context 连续渲染 ---------------- */
    {
        EGLDisplay dpy = make_display();
        if (dpy == EGL_NO_DISPLAY) { printf("FAIL: eglInitialize (A)\n"); return 1; }

        EGLint attrs[] = {
            EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
            EGL_RED_SIZE,8, EGL_GREEN_SIZE,8, EGL_BLUE_SIZE,8, EGL_ALPHA_SIZE,8,
            EGL_NONE
        };
        EGLConfig cfg; EGLint n = 0;
        if (!eglChooseConfig(dpy, attrs, &cfg, 1, &n) || n < 1) {
            printf("FAIL: eglChooseConfig (A)\n"); return 1;
        }
        EGLint pb[] = { EGL_WIDTH, W, EGL_HEIGHT, H, EGL_NONE };
        EGLSurface surf = eglCreatePbufferSurface(dpy, cfg, pb);
        EGLint ca[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
        EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ca);
        if (surf == EGL_NO_SURFACE || ctx == EGL_NO_CONTEXT || !eglMakeCurrent(dpy, surf, surf, ctx)) {
            printf("FAIL: context setup (A)\n"); return 1;
        }

        GLuint prog = build_program();
        if (!prog) { printf("FAIL: shader/program (A)\n"); return 1; }

        printf("GL_RENDERER: %s\n", glGetString(GL_RENDERER));

        t0 = time(NULL);
        int bad = 0;
        for (int f = 1; f <= frames; f++) {
            /* 每帧都绘制；每 500 帧抽样校验一次像素（读回开销大） */
            int check = (f % 500 == 0) || (f == 1) || (f == frames);
            if (check) {
                if (!draw_one(prog, W, H)) { bad++; printf("BAD pixel at frame %d\n", f); }
            } else {
                static const GLfloat verts[] = {
                    -1.f,-1.f, 0,1,0,  1.f,-1.f, 0,1,0,  1.f,1.f, 0,1,0,
                    -1.f,-1.f, 0,1,0,  1.f,1.f, 0,1,0,  -1.f,1.f, 0,1,0,
                };
                glClear(GL_COLOR_BUFFER_BIT);
                glUseProgram(prog);
                glEnableVertexAttribArray(0);
                glEnableVertexAttribArray(1);
                glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,5*sizeof(GLfloat),&verts[0]);
                glVertexAttribPointer(1,3,GL_FLOAT,GL_FALSE,5*sizeof(GLfloat),&verts[2]);
                glDrawArrays(GL_TRIANGLES, 0, 6);
            }
        }
        glFinish();
        printf("A: %d frames done in %ld s, bad=%d\n", frames, (long)(time(NULL)-t0), bad);

        eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroyContext(dpy, ctx);
        eglDestroySurface(dpy, surf);
        eglTerminate(dpy);
        if (bad) { printf("RESULT A: FAIL\n"); return 1; }
        printf("RESULT A: PASS (%d frames)\n", frames);
    }

    /* ---------------- 测试 B：反复创建/销毁 context ---------------- */
    {
        t0 = time(NULL);
        int fails = 0;
        for (int i = 1; i <= ctx_loops; i++) {
            EGLDisplay dpy = make_display();
            if (dpy == EGL_NO_DISPLAY) { fails++; printf("FAIL init ctx#%d\n", i); continue; }

            EGLint attrs[] = {
                EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                EGL_NONE
            };
            EGLConfig cfg; EGLint n = 0;
            if (!eglChooseConfig(dpy, attrs, &cfg, 1, &n) || n < 1) {
                fails++; eglTerminate(dpy); continue;
            }
            EGLint pb[] = { EGL_WIDTH, 64, EGL_HEIGHT, 64, EGL_NONE };
            EGLSurface s = eglCreatePbufferSurface(dpy, cfg, pb);
            EGLint ca[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
            EGLContext c = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ca);
            if (s == EGL_NO_SURFACE || c == EGL_NO_CONTEXT) {
                fails++; eglTerminate(dpy); continue;
            }
            if (!eglMakeCurrent(dpy, s, s, c)) {
                fails++; eglTerminate(dpy); continue;
            }

            GLuint p = build_program();
            if (!p || !draw_one(p, 64, 64)) fails++;

            eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            eglDestroyContext(dpy, c);
            eglDestroySurface(dpy, s);
            eglTerminate(dpy);

            if (i % 20 == 0) printf("  ctx %d/%d ok (fails=%d)\n", i, ctx_loops, fails);
        }
        printf("B: %d context cycles in %ld s, fails=%d\n",
               ctx_loops, (long)(time(NULL)-t0), fails);
        if (fails) { printf("RESULT B: FAIL\n"); return 1; }
        printf("RESULT B: PASS (%d cycles)\n", ctx_loops);
    }

    printf("RESULT: PASS\n");
    return 0;
}