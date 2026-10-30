#!/usr/bin/env swift
// Composes Myra icon renditions with the macOS icon grid.
//
//   compose-myra-icon.swift compose <body.png> <out.png> <canvas>
//     Places the squircle body (already rendered at 824/1024 of the canvas) in the middle of a
//     transparent canvas with a soft drop shadow: offset 10 px down, blur 28 px and 30% black at a
//     1024 px canvas, scaled proportionally for smaller canvases.
//   compose-myra-icon.swift resize <in.png> <out.png> <size>
//     Resamples a composed master to a smaller square size with high-quality interpolation.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func load(_ path: String) -> CGImage {
  guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else { fatalError("Cannot read \(path)") }
  return image
}

func write(_ image: CGImage, to path: String) {
  guard
    let destination = CGImageDestinationCreateWithURL(
      URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { fatalError("Cannot write \(path)") }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { fatalError("Cannot finish \(path)") }
}

func context(size: Int) -> CGContext {
  guard
    let context = CGContext(
      data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { fatalError("No context") }
  context.interpolationQuality = .high
  return context
}

let arguments = CommandLine.arguments
guard arguments.count == 5, let size = Int(arguments[4]) else {
  fatalError("usage: compose-myra-icon.swift compose|resize <in> <out> <size>")
}
let input = load(arguments[2])

switch arguments[1] {
case "compose":
  let scale = CGFloat(size) / 1024
  let body = (824 * scale).rounded()
  let origin = (CGFloat(size) - body) / 2
  let canvas = context(size: size)
  canvas.setShadow(
    offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale,
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
  canvas.draw(input, in: CGRect(x: origin, y: origin, width: body, height: body))
  write(canvas.makeImage()!, to: arguments[3])
case "resize":
  let canvas = context(size: size)
  canvas.draw(input, in: CGRect(x: 0, y: 0, width: size, height: size))
  write(canvas.makeImage()!, to: arguments[3])
default:
  fatalError("unknown mode \(arguments[1])")
}
