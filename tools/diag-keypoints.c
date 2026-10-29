/*
 * Diagnostic: SIGFM keypoint count for a captured PGM frame, plus how it
 * changes under controlled degradation and local contrast enhancement.
 *
 * The driver rejects a frame below 25 keypoints ("No enough keypoints found"),
 * which fprintd surfaces as `verify-retry-scan`. This tool measures how far a
 * given frame is from that threshold and how much headroom it has.
 *
 * Development tool only; not part of the build.
 *
 * Build (libsigfm.a is C++, so link with g++, not gcc):
 *
 *   g++ -O2 -o diag-keypoints tools/diag-keypoints.c \
 *       -Ilibfprint -I. \
 *       $(pkg-config --cflags --libs opencv4) \
 *       build/libfprint/sigfm/libsigfm.a -lm
 *
 * Usage:
 *
 *   diag-keypoints goodix-*.pgm
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

extern "C" {
#include "sigfm/sigfm.h"
}

#define KEYPOINT_THRESHOLD 25

static int
load_pgm (const char *path, unsigned char **out, int *w, int *h)
{
  FILE *f = fopen (path, "rb");
  char magic[3] = { 0 };
  int maxval, n;
  size_t got;

  if (!f)
    return 0;
  if (fscanf (f, "%2s %d %d %d", magic, w, h, &maxval) != 4)
    {
      fclose (f);
      return 0;
    }
  fgetc (f);                     /* single whitespace before the raster */

  n = (*w) * (*h);
  *out = (unsigned char *) malloc (n);
  got = fread (*out, 1, n, f);
  fclose (f);

  return (int) got == n;
}

static int
keypoints_of (const unsigned char *img, int w, int h)
{
  SigfmImgInfo *info = sigfm_extract (img, w, h);
  int kp = info ? sigfm_keypoints_count (info) : -1;

  if (info)
    sigfm_free_info (info);
  return kp;
}

/* Box blur with the given radius. */
static void
blur (const unsigned char *src, unsigned char *dst, int w, int h, int r)
{
  for (int y = 0; y < h; y++)
    for (int x = 0; x < w; x++)
      {
        int sum = 0, n = 0;

        for (int dy = -r; dy <= r; dy++)
          for (int dx = -r; dx <= r; dx++)
            {
              int yy = y + dy, xx = x + dx;

              if (yy < 0 || yy >= h || xx < 0 || xx >= w)
                continue;
              sum += src[yy * w + xx];
              n++;
            }
        dst[y * w + x] = (unsigned char) (sum / n);
      }
}

/* Scale contrast around mid-grey. */
static void
scale_contrast (const unsigned char *src, unsigned char *dst, int n, double k)
{
  for (int i = 0; i < n; i++)
    {
      double v = 128.0 + (src[i] - 128.0) * k;

      dst[i] = (unsigned char) (v < 0 ? 0 : (v > 255 ? 255 : v));
    }
}

/* Simulate partial finger coverage: keep the left `frac` of the frame, fill the
 * rest with the frame mean. */
static void
partial_coverage (const unsigned char *src, unsigned char *dst,
                  int w, int h, double frac)
{
  int keep = (int) (w * frac);
  long sum = 0;

  for (int i = 0; i < w * h; i++)
    sum += src[i];

  memcpy (dst, src, (size_t) w * h);
  for (int y = 0; y < h; y++)
    for (int x = keep; x < w; x++)
      dst[y * w + x] = (unsigned char) (sum / (w * h));
}

/* Global histogram equalisation. */
static void
equalize_global (const unsigned char *src, unsigned char *dst, int n)
{
  int hist[256] = { 0 }, cdf[256], acc = 0;

  for (int i = 0; i < n; i++)
    hist[src[i]]++;
  for (int i = 0; i < 256; i++)
    {
      acc += hist[i];
      cdf[i] = acc;
    }
  for (int i = 0; i < n; i++)
    dst[i] = (unsigned char) (cdf[src[i]] * 255 / cdf[255]);
}

/* Per-tile histogram equalisation (a cheap CLAHE stand-in). */
static void
equalize_local (const unsigned char *src, unsigned char *dst,
                int w, int h, int tile)
{
  for (int ty = 0; ty < h; ty += tile)
    {
      for (int tx = 0; tx < w; tx += tile)
        {
          int tw = (tx + tile > w) ? (w - tx) : tile;
          int th = (ty + tile > h) ? (h - ty) : tile;
          int hist[256] = { 0 }, cdf[256], acc = 0, n = tw * th;

          for (int y = ty; y < ty + th; y++)
            for (int x = tx; x < tx + tw; x++)
              hist[src[y * w + x]]++;

          for (int i = 0; i < 256; i++)
            {
              acc += hist[i];
              cdf[i] = acc;
            }

          for (int y = ty; y < ty + th; y++)
            for (int x = tx; x < tx + tw; x++)
              dst[y * w + x] = (unsigned char) (cdf[src[y * w + x]] * 255 / n);
        }
    }
}

static void
report (const char *label, int kp, int base)
{
  printf ("  %-26s %-6d", label, kp);

  if (base > 0)
    printf (" %+d", kp - base);
  else
    printf (" -");

  if (kp < KEYPOINT_THRESHOLD)
    printf ("   REJECTED (<%d)", KEYPOINT_THRESHOLD);
  printf ("\n");
}

int
main (int argc, char **argv)
{
  if (argc < 2)
    {
      fprintf (stderr, "usage: %s frame.pgm [frame.pgm ...]\n", argv[0]);
      return 1;
    }

  for (int a = 1; a < argc; a++)
    {
      unsigned char *img = NULL, *tmp;
      int w, h, n, base;

      if (!load_pgm (argv[a], &img, &w, &h))
        {
          fprintf (stderr, "%s: cannot read PGM\n", argv[a]);
          continue;
        }

      n = w * h;
      tmp = (unsigned char *) malloc (n);
      base = keypoints_of (img, w, h);

      printf ("%s (%dx%d)\n", argv[a], w, h);
      printf ("  %-26s %-6d %s\n", "original", base,
              base < KEYPOINT_THRESHOLD ? "REJECTED" : "");

      printf ("\n  -- contrast scaling --\n");
      for (double k = 0.8; k >= 0.1; k -= 0.15)
        {
          char label[64];

          scale_contrast (img, tmp, n, k);
          snprintf (label, sizeof (label), "contrast x%.2f", k);
          report (label, keypoints_of (tmp, w, h), base);
        }

      printf ("\n  -- blur (pressure / smear) --\n");
      for (int r = 1; r <= 3; r++)
        {
          char label[64];

          blur (img, tmp, w, h, r);
          snprintf (label, sizeof (label), "blur radius %d", r);
          report (label, keypoints_of (tmp, w, h), base);
        }

      printf ("\n  -- partial coverage (off-angle press) --\n");
      for (double c = 0.9; c >= 0.4; c -= 0.15)
        {
          char label[64];

          partial_coverage (img, tmp, w, h, c);
          snprintf (label, sizeof (label), "coverage %.2f", c);
          report (label, keypoints_of (tmp, w, h), base);
        }

      printf ("\n  -- contrast enhancement --\n");
      equalize_global (img, tmp, n);
      report ("global equalisation", keypoints_of (tmp, w, h), base);
      equalize_local (img, tmp, w, h, 16);
      report ("local equalisation (16px)", keypoints_of (tmp, w, h), base);

      printf ("\n");
      free (tmp);
      free (img);
    }

  return 0;
}
