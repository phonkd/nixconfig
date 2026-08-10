/* goodix-521d-minutiae-check -- why the g14's fingerprint reader cannot verify.
 *
 * This is the evidence behind services.fprintd.enable = false in
 * modules/hosts/g14.nix. Keep it so the conclusion stays falsifiable: if
 * someone doubts the verdict, they can re-run it rather than re-argue it.
 *
 * Background. The Goodix 521d enrols fine but every verify scores 0 against
 * bozorth3's threshold of 24. That could mean a bad capture (fixable) or a
 * sensor too small to carry features (not fixable). Match scores alone cannot
 * tell those apart, so this runs libfprint's own NBIS minutiae detector over
 * the raw captures and counts what it finds.
 *
 * Getting captures: build the driver with the GOODIX52XD_DUMP escape hatch and
 * run the daemon by hand, then enrol/verify as usual --
 *
 *   sudo systemctl stop fprintd
 *   sudo env G_MESSAGES_DEBUG=all GOODIX52XD_DUMP=/tmp/goodix \
 *     "$(nix build --no-link --print-out-paths --impure \
 *        .#nixosConfigurations.g14.config.services.fprintd.package)"/libexec/fprintd -t
 *
 * Building and running this. The patched libfprint carries its own headers in
 * its single output, so pick it out of fprintd's references:
 *
 *   FPRINTD=$(nix build --no-link --print-out-paths --impure \
 *             .#nixosConfigurations.g14.config.services.fprintd.package)
 *   LFP=$(nix-store -q --references "$FPRINTD" | grep -m1 libfprint-goodixtls)
 *   nix-shell -p gcc pkg-config glib.dev --run "
 *     gcc -O2 -o /tmp/mincheck scripts/goodix-521d-minutiae-check.c \
 *       \$(pkg-config --cflags glib-2.0 gobject-2.0) -I$LFP/include \
 *       -L$LFP/lib -lfprint-2 \$(pkg-config --libs glib-2.0 gobject-2.0) \
 *       -Wl,-rpath,$LFP/lib"
 *   /tmp/mincheck /tmp/goodix-*.pgm
 *
 * What it found (2026-08-10, 13 captures): 0-2 minutiae each. The binarized
 * images it writes alongside show clean, correctly-thresholded parallel ridges,
 * so detection is working -- there is simply almost nothing to detect. Measuring
 * the ridge period in those images (~12.8 px, ~5 ridges across the 64 px width)
 * puts the window at roughly 2.3 x 2.8 mm = 6.3 mm^2, which at a normal minutia
 * density of 0.2-0.3/mm^2 should hold 1-2 minutiae. Observed matches predicted.
 * bozorth3 needs far more than that to reach 24, so no amount of driver work
 * will help.
 */
#include <libfprint-2/fprint.h>
#include <stdio.h>
#include <string.h>

typedef struct {
  GMainLoop *loop;
  char *name;
} Ctx;

static guchar *read_pgm(const char *path, int *w, int *h) {
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); return NULL; }

  char magic[3] = { 0 };
  int maxv = 0;
  if (fscanf(f, "%2s %d %d %d", magic, w, h, &maxv) != 4 ||
      strcmp(magic, "P5") != 0) {
    fprintf(stderr, "%s: not a binary PGM\n", path);
    fclose(f);
    return NULL;
  }
  fgetc(f); /* the single whitespace byte after maxval */

  gsize n = (gsize) *w * *h;
  guchar *buf = g_malloc(n);
  if (fread(buf, 1, n, f) != n) {
    fprintf(stderr, "%s: short read\n", path);
    g_free(buf);
    fclose(f);
    return NULL;
  }
  fclose(f);
  return buf;
}

static void write_pgm(const char *path, const guchar *data, int w, int h) {
  FILE *f = fopen(path, "wb");
  if (!f) { perror(path); return; }
  fprintf(f, "P5\n%d %d\n255\n", w, h);
  fwrite(data, 1, (gsize) w * h, f);
  fclose(f);
}

static void on_done(GObject *src, GAsyncResult *res, gpointer user_data) {
  Ctx *ctx = user_data;
  FpImage *img = FP_IMAGE(src);
  g_autoptr(GError) error = NULL;

  /* libfprint reports "no minutiae found" as a failure, which is itself the
   * result we care about -- report it rather than treating it as an error. */
  if (!fp_image_detect_minutiae_finish(img, res, &error)) {
    printf("%-18s minutiae=0   (%s)\n", ctx->name,
           error ? error->message : "detection failed");
    g_main_loop_quit(ctx->loop);
    return;
  }

  GPtrArray *minutiae = fp_image_get_minutiae(img);
  guint w = fp_image_get_width(img), h = fp_image_get_height(img);
  printf("%-18s minutiae=%-3u %ux%u\n", ctx->name,
         minutiae ? minutiae->len : 0, w, h);

  /* The binarized image is what mindtct actually traces. Dumping it separates
   * "the capture is noise" from "the capture is fine but featureless". */
  gsize blen = 0;
  const guchar *bin = fp_image_get_binarized(img, &blen);
  if (bin && blen == (gsize) w * h) {
    g_autofree char *out = g_strdup_printf("/tmp/binarized-%s", ctx->name);
    write_pgm(out, bin, w, h);
  }

  g_main_loop_quit(ctx->loop);
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <capture.pgm>...\n", argv[0]);
    return 2;
  }

  for (int i = 1; i < argc; i++) {
    int w = 0, h = 0;
    guchar *raw = read_pgm(argv[i], &w, &h);
    if (!raw) continue;

    FpImage *img = fp_image_new(w, h);
    gsize len = 0;
    guchar *dst = (guchar *) fp_image_get_data(img, &len);
    memcpy(dst, raw, MIN(len, (gsize) w * h));
    g_free(raw);

    Ctx ctx = {
      .loop = g_main_loop_new(NULL, FALSE),
      .name = g_path_get_basename(argv[i]),
    };
    fp_image_detect_minutiae(img, NULL, on_done, &ctx);
    g_main_loop_run(ctx.loop);

    g_main_loop_unref(ctx.loop);
    g_free(ctx.name);
    g_object_unref(img);
  }
  return 0;
}
