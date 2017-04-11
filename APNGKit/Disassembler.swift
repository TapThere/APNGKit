//
//  Disassembler.swift
//  APNGKit
//
//  Created by Wei Wang on 15/8/27.
//
//  Copyright (c) 2015 Wei Wang <onevcat@gmail.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import UIKit

let signatureOfPNGLength = 8
let kMaxPNGSize: UInt32 = 1000000;

// Reading callback for libpng
func readData(_ pngPointer: png_structp?, outBytes: png_bytep?, byteCountToRead: png_size_t) {
    if pngPointer == nil || outBytes == nil {
        return
    }
    
    let ioPointer = png_get_io_ptr(pngPointer)
    var reader = UnsafeRawPointer(ioPointer)!.load(as: Reader.self)
    
    _ = reader.read(outBytes!, bytesCount: byteCountToRead)
}

/**
Disassembler Errors. An error will be thrown if the disassembler encounters 
unexpected error.

- InvalidFormat:       The file is not a PNG format.
- PNGStructureFailure: Fail on creating a PNG structure. It might due to out of memory.
- PNGInternalError:    Internal error when decoding a PNG image.
- FileSizeExceeded:    The file is too large. There is a limitation of APNGKit that the max width and height is 1M pixel.
*/
public enum DisassemblerError: Error {
    case invalidFormat
    case pngStructureFailure
    case pngInternalError
    case fileSizeExceeded
}


public struct APNGContent {
    public let images : [UIImage]
    public let size : CGSize
    public let repeatCount : Int
    public let bitDepth : Int
    public let firstFrameHidden : Bool
    
}

/**
*  Disassemble APNG data. 
*  See APNG Specification: https://wiki.mozilla.org/APNG_Specification for defination of APNG.
*  This Disassembler is using a patched libpng with supporting of apng to read APNG data.
*  See https://github.com/onevcat/libpng for more.
*/
public struct Disassembler {
    fileprivate(set) var reader: Reader
    let originalData: Data
    
    /**
    Init a disassembler with APNG data.
    
    - parameter data: Data object of an APNG file.
    
    - returns: The disassembler ready to use.
    */
    public init(data: Data) {
        reader = Reader(data: data)
        originalData = data
    }
    
    /**
    Decode the data to a high level `APNGImage` object.
    
    - parameter scale: The screen scale should be used when decoding. 
    You should pass 1 if you want to use the dosassembler separately.
    If you need to display the image on the screen later, use `UIScreen.mainScreen().scale`.
    Default is 1.0.
    
    - throws: A `DisassemblerError` when error happens.
    
    - returns: A decoded `APNGImage` object at given scale.
    */
    public mutating func decode(_ scale: CGFloat = 1) throws -> APNGImage {
        let (frames, size, repeatCount, bitDepth, firstFrameHidden) = try decodeToElements(scale)
        
        // Setup apng properties
        let apng = APNGImage(frames: frames, size: size, scale: scale,
            bitDepth: bitDepth, repeatCount: repeatCount, firstFrameHidden: firstFrameHidden)
        return apng
    }
    
    public mutating func decode(scale: CGFloat = 1) throws -> APNGContent
    {
        let (frames, size, repeatCount, bitDepth, firstFrameHidden) = try decodeToElements(scale)
        
        return APNGContent(images: frames.map { return $0.image! }, size: size, repeatCount: repeatCount, bitDepth: bitDepth, firstFrameHidden: firstFrameHidden)
    }
    
    
    mutating func decodeToElements(_ scale: CGFloat = 1) throws
            -> (frames: [Frame], size: CGSize, repeatCount: Int, bitDepth: Int, firstFrameHidden: Bool)
    {
        reader.beginReading()
        defer {
            reader.endReading()
        }
        
        try checkFormat()
        
        var pngPointer = png_create_read_struct(PNG_LIBPNG_VER_STRING, nil, nil, nil)
        
        if pngPointer == nil {
            throw DisassemblerError.pngStructureFailure
        }
        
        var infoPointer = png_create_info_struct(pngPointer)
        
        defer {
            png_destroy_read_struct(&pngPointer, &infoPointer, nil)
        }
        
        if infoPointer == nil {
            throw DisassemblerError.pngStructureFailure
        }
        
        if png_jmpbuf(pngPointer).pointee != 0 {
            throw DisassemblerError.pngInternalError
        }
        
        png_set_read_fn(pngPointer, &reader, readData)
        png_read_info(pngPointer, infoPointer)
        
        var
        width: UInt32 = 0,
        height: UInt32 = 0,
        bitDepth: Int32 = 0,
        colorType: Int32 = 0
        
        // Decode IHDR
        png_get_IHDR(pngPointer, infoPointer, &width, &height, &bitDepth, &colorType, nil, nil, nil)
        
        if width > kMaxPNGSize || height > kMaxPNGSize {
            throw DisassemblerError.fileSizeExceeded
        }
                
        // Transforms. We only handle 8-bit RGBA images.
        png_set_expand(pngPointer)
        
        if bitDepth == 16 {
            png_set_strip_16(pngPointer)
        }
        
        if colorType == PNG_COLOR_TYPE_GRAY || colorType == PNG_COLOR_TYPE_GRAY_ALPHA {
            png_set_gray_to_rgb(pngPointer);
        }
        
        if colorType == PNG_COLOR_TYPE_RGB || colorType == PNG_COLOR_TYPE_PALETTE || colorType == PNG_COLOR_TYPE_GRAY {
            png_set_add_alpha(pngPointer, 0xff, PNG_FILLER_AFTER);
        }
        
        png_set_interlace_handling(pngPointer);
        png_read_update_info(pngPointer, infoPointer);
        
        // Update information from updated info pointer
        width = png_get_image_width(pngPointer, infoPointer)
        height = png_get_image_height(pngPointer, infoPointer)
        let rowBytes = UInt32(png_get_rowbytes(pngPointer, infoPointer))
        let length = height * rowBytes
        
        // Decode acTL
        var frameCount: UInt32 = 0, playCount: UInt32 = 0
        png_get_acTL(pngPointer, infoPointer, &frameCount, &playCount)
        
        if frameCount == 0 {
            // Fallback to regular PNG
            var currentFrame = Frame(length: length, bytesInRow: rowBytes)
            currentFrame.duration = Double.infinity
            
            currentFrame.byteRows.withUnsafeMutableBufferPointer({ (buffer) in
                _ = withUnsafeMutablePointer(to: &buffer) { (bound) in
                    bound.withMemoryRebound(to: (UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>).self, capacity: MemoryLayout<(UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>)>.size) { (rows) in
                        let mappedRows: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>> = rows
                        png_read_image(pngPointer, mappedRows.pointee)
                    }
                }
            })
            
            currentFrame.updateCGImageRef(Int(width), height: Int(height), bits: Int(bitDepth), scale: scale, blend: false)
            
            png_read_end(pngPointer, infoPointer)
            return ([currentFrame], CGSize(width: CGFloat(width), height: CGFloat(height)), Int(playCount) - 1, Int(bitDepth), false)
        }
        
        var bufferFrame = Frame(length: length, bytesInRow: rowBytes)
        var currentFrame = Frame(length: length, bytesInRow: rowBytes)
        var nextFrame: Frame!
        
        // Setup values for reading frames
        var
        frameWidth: UInt32 = 0,
        frameHeight: UInt32 = 0,
        offsetX: UInt32 = 0,
        offsetY: UInt32 = 0,
        delayNum: UInt16 = 0,
        delayDen: UInt16 = 0,
        disposeOP: UInt8 = 0,
        blendOP: UInt8 = 0
        
        let firstImageIndex: Int
        let firstFrameHidden = png_get_first_frame_is_hidden(pngPointer, infoPointer) != 0
        firstImageIndex = firstFrameHidden ? 1 : 0
        
        var frames = [Frame]()
        
        // Decode frames
        for i in 0 ..< frameCount {
            let currentIndex = Int(i)
            // Read header
            png_read_frame_head(pngPointer, infoPointer)
            // Decode fcTL
            png_get_next_frame_fcTL(pngPointer, infoPointer, &frameWidth, &frameHeight,
                &offsetX, &offsetY, &delayNum, &delayDen, &disposeOP, &blendOP)
            
            // Update disposeOP for first visable frame
            if currentIndex == firstImageIndex {
                blendOP = UInt8(PNG_BLEND_OP_SOURCE)
                if disposeOP == UInt8(PNG_DISPOSE_OP_PREVIOUS) {
                    disposeOP = UInt8(PNG_DISPOSE_OP_BACKGROUND)
                }
            }
            
            nextFrame = Frame(length: length, bytesInRow: rowBytes)
            
            if (disposeOP == UInt8(PNG_DISPOSE_OP_PREVIOUS)) {
                // For the first frame, currentFrame is not inited yet.
                // But we can ensure the disposeOP is not PNG_DISPOSE_OP_PREVIOUS for the 1st frame
                memcpy(nextFrame.bytes, currentFrame.bytes, Int(length));
            }
            
            // Decode fdATs
            bufferFrame.byteRows.withUnsafeMutableBufferPointer({ (buffer) in
                _ = withUnsafeMutablePointer(to: &buffer) { (bound) in
                    bound.withMemoryRebound(to: (UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>).self, capacity: MemoryLayout<(UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>)>.size) { (rows) in
                        let mappedRows: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>> = rows
                        png_read_image(pngPointer, mappedRows.pointee)
                    }
                }
            })
            
            
            _ = withUnsafeMutablePointer(to: &currentFrame.byteRows) { (currentBind) in
                currentBind.withMemoryRebound(to: Array<UnsafeMutablePointer<UInt8>>.self, capacity: currentFrame.byteRows.count) { (currentRows) in
                    let destRows: UnsafeMutablePointer<Array<UnsafeMutablePointer<UInt8>>> = currentRows
                    
                    _ = withUnsafeMutablePointer(to: &bufferFrame.byteRows) { (bufferBind) in
                        bufferBind.withMemoryRebound(to: Array<UnsafeMutablePointer<UInt8>>.self, capacity: bufferFrame.byteRows.count) { (bufferRows) in
                            let srcRows: UnsafeMutablePointer<Array<UnsafeMutablePointer<UInt8>>> = bufferRows
                            
                            blendFrameDstBytes(destRows.pointee, srcBytes: srcRows.pointee, blendOP: blendOP, offsetX: offsetX, offsetY: offsetY, width: frameWidth, height: frameHeight)
                        }
                    }
                }
            }
            
            
            // Calculating delay (duration)
            if delayDen == 0 {
                delayDen = 100
            }
            let duration = Double(delayNum) / Double(delayDen)
            currentFrame.duration = duration

            currentFrame.updateCGImageRef(Int(width), height: Int(height), bits: Int(bitDepth), scale: scale, blend: blendOP != UInt8(PNG_BLEND_OP_SOURCE))
            
            frames.append(currentFrame)
            
            if disposeOP != UInt8(PNG_DISPOSE_OP_PREVIOUS) {
                memcpy(nextFrame.bytes, currentFrame.bytes, Int(length))
                if disposeOP == UInt8(PNG_DISPOSE_OP_BACKGROUND) {
                    for j in 0 ..< frameHeight {
                        let tarPointer = nextFrame.byteRows[Int(offsetY + j)].advanced(by: Int(offsetX) * 4)
                        memset(tarPointer, 0, Int(frameWidth) * 4)
                    }
                }
            }
            
            currentFrame.bytes = nextFrame.bytes
            currentFrame.byteRows = nextFrame.byteRows
        }
        
        // End
        png_read_end(pngPointer, infoPointer)
        
        bufferFrame.clean()
        currentFrame.clean()
                
        return (frames, CGSize(width: CGFloat(width), height: CGFloat(height)), Int(playCount) - 1, Int(bitDepth), firstFrameHidden)
    }
    
    func blendFrameDstBytes(_ dstBytes: Array<UnsafeMutablePointer<UInt8>>,
                            srcBytes: Array<UnsafeMutablePointer<UInt8>>,
                             blendOP: UInt8,
                             offsetX: UInt32,
                             offsetY: UInt32,
                               width: UInt32,
                              height: UInt32)
    {
        var u: Int = 0, v: Int = 0, al: Int = 0
        
        for j in 0 ..< Int(height) {
            var sp = srcBytes[j]
            var dp = (dstBytes[j + Int(offsetY)]).advanced(by: Int(offsetX) * 4) //We will always handle 4 channels and 8-bits
            
            if blendOP == UInt8(PNG_BLEND_OP_SOURCE) {
                memcpy(dp, sp, Int(width) * 4)
            } else { // APNG_BLEND_OP_OVER
                for _ in 0 ... Int(width){
                    sp = sp.advanced(by: 4)
                    dp = dp.advanced(by: 4)
                    let srcAlpha = Int(sp.advanced(by: 3).pointee) // Blend alpha to dst
                    if srcAlpha == 0xff {
                        memcpy(dp, sp, 4)
                    } else if srcAlpha != 0 {
                        let dstAlpha = Int(dp.advanced(by: 3).pointee)
                        if dstAlpha != 0 {
                            u = srcAlpha * 255
                            v = (255 - srcAlpha) * dstAlpha
                            al = u + v
                            
                            for bit in 0 ..< 3 {
                                dp.advanced(by: bit).pointee = UInt8(
                                    (Int(sp.advanced(by: bit).pointee) * u + Int(dp.advanced(by: bit).pointee) * v) / al
                                )
                            }
                            
                            dp.advanced(by: 4).pointee = UInt8(al / 255)
                        } else {
                            memcpy(dp, sp, 4)
                        }
                    }
                }
            }
        }
    }
    
    func checkFormat() throws {
        guard originalData.count > 8 else {
            throw DisassemblerError.invalidFormat
        }
        
        var sig = [UInt8](repeating: 0, count: signatureOfPNGLength)
        (originalData as NSData).getBytes(&sig, length: signatureOfPNGLength)
        
        guard png_sig_cmp(&sig, 0, signatureOfPNGLength) == 0 else {
            throw DisassemblerError.invalidFormat
        }
    }
}
