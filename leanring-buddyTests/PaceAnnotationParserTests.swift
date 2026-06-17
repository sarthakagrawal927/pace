//
//  PaceAnnotationParserTests.swift
//  leanring-buddyTests
//
//  Covers the tuition-mode `draw_annotation` / `clear_annotations`
//  parsing surface on both planner paths (v10 envelope and legacy
//  `<tool_calls>` JSON block). Exercises the shape grammar (rect,
//  ellipse, line, arrow, polygon), default styling, clamping, label
//  sanitization, and the failure cases that should drop a malformed
//  shape entirely.
//

import CoreGraphics
import Foundation
import Testing
@testable import Pace

struct PaceAnnotationParserTests {

    // MARK: - Each shape kind round-trips through the v10 envelope

    @Test func rectShapeParsesFromV10Envelope() async throws {
        let plannerResponse = #"""
        {
          "spokenText": "look at the save button.",
          "intent": "action",
          "payload": {"name":"draw_annotation","args":{"shapes":[{"kind":"rect","x":100,"y":80,"width":200,"height":60}]}}
        }
        """#
        let parseResult = PaceActionTagParser.parseActions(from: plannerResponse)
        try #require(parseResult.actions.count == 1)
        guard case .drawAnnotation(let annotationRequest) = parseResult.actions[0] else {
            Issue.record("Expected drawAnnotation action")
            return
        }
        #expect(annotationRequest.shapes.count == 1)
        guard case .rect(let x, let y, let width, let height, _) = annotationRequest.shapes[0] else {
            Issue.record("Expected rect shape")
            return
        }
        #expect(x == 100 && y == 80 && width == 200 && height == 60)
    }

    @Test func ellipseShapeParsesViaCircleAlias() async throws {
        let plannerResponse = #"""
        {
          "spokenText": "",
          "intent": "action",
          "payload": {"name":"draw_annotation","args":{"shapes":[{"kind":"circle","x":300,"y":200,"width":50,"height":50}]}}
        }
        """#
        let parseResult = PaceActionTagParser.parseActions(from: plannerResponse)
        try #require(parseResult.actions.count == 1)
        guard case .drawAnnotation(let annotationRequest) = parseResult.actions[0],
              case .ellipse(_, _, let width, let height, _) = annotationRequest.shapes[0] else {
            Issue.record("Expected ellipse from circle alias")
            return
        }
        #expect(width == 50 && height == 50)
    }

    @Test func ellipseShapeParsesFromRadius() async throws {
        // Planner shorthand: circles can be expressed as (center x, center y, radius).
        let plannerResponse = #"""
        {
          "spokenText": "",
          "intent": "action",
          "payload": {"name":"draw_annotation","args":{"shapes":[{"kind":"circle","x":400,"y":300,"radius":40}]}}
        }
        """#
        let parseResult = PaceActionTagParser.parseActions(from: plannerResponse)
        try #require(parseResult.actions.count == 1)
        guard case .drawAnnotation(let annotationRequest) = parseResult.actions[0],
              case .ellipse(let x, let y, let width, let height, _) = annotationRequest.shapes[0] else {
            Issue.record("Expected ellipse from radius")
            return
        }
        #expect(x == 360 && y == 260 && width == 80 && height == 80)
    }

    @Test func lineShapeParsesFromV10Envelope() async throws {
        let plannerResponse = #"""
        {
          "spokenText": "",
          "intent": "action",
          "payload": {"name":"draw_annotation","args":{"shapes":[{"kind":"line","x1":10,"y1":20,"x2":300,"y2":400}]}}
        }
        """#
        let parseResult = PaceActionTagParser.parseActions(from: plannerResponse)
        try #require(parseResult.actions.count == 1)
        guard case .drawAnnotation(let annotationRequest) = parseResult.actions[0],
              case .line(let x1, let y1, let x2, let y2, _) = annotationRequest.shapes[0] else {
            Issue.record("Expected line shape")
            return
        }
        #expect(x1 == 10 && y1 == 20 && x2 == 300 && y2 == 400)
    }

    @Test func arrowShapeParsesFromV10Envelope() async throws {
        let plannerResponse = #"""
        {
          "spokenText": "",
          "intent": "action",
          "payload": {"name":"draw_annotation","args":{"shapes":[{"kind":"arrow","x1":50,"y1":60,"x2":250,"y2":160}]}}
        }
        """#
        let parseResult = PaceActionTagParser.parseActions(from: plannerResponse)
        try #require(parseResult.actions.count == 1)
        guard case .drawAnnotation(let annotationRequest) = parseResult.actions[0],
              case .arrow(let tailX, let tailY, let headX, let headY, _) = annotationRequest.shapes[0] else {
            Issue.record("Expected arrow shape")
            return
        }
        #expect(tailX == 50 && tailY == 60 && headX == 250 && headY == 160)
    }

    @Test func pentagonParsesAsPolygonWithFiveVertices() async throws {
        let plannerResponse = #"""
        {
          "spokenText": "",
          "intent": "action",
          "payload": {"name":"draw_annotation","args":{"shapes":[{"kind":"polygon","points":[[100,50],[150,90],[130,150],[70,150],[50,90]]}]}}
        }
        """#
        let parseResult = PaceActionTagParser.parseActions(from: plannerResponse)
        try #require(parseResult.actions.count == 1)
        guard case .drawAnnotation(let annotationRequest) = parseResult.actions[0],
              case .polygon(let points, _) = annotationRequest.shapes[0] else {
            Issue.record("Expected polygon shape")
            return
        }
        #expect(points.count == 5)
        #expect(points[0].x == 100 && points[0].y == 50)
    }

    // MARK: - Styling: color defaults, clamping, label sanitation

    @Test func unrecognizedColorFallsBackToRed() async throws {
        let plannerResponse = #"""
        {
          "spokenText": "",
          "intent": "action",
          "payload": {"name":"draw_annotation","args":{"shapes":[{"kind":"rect","x":0,"y":0,"width":1,"height":1,"color":"fuchsia"}]}}
        }
        """#
        let parseResult = PaceActionTagParser.parseActions(from: plannerResponse)
        guard case .drawAnnotation(let annotationRequest) = parseResult.actions[0] else {
            Issue.record("Expected drawAnnotation")
            return
        }
        #expect(annotationRequest.shapes[0].style.color == .red)
    }

    @Test func strokeWidthClampedToSafeRange() async throws {
        let plannerResponseTooThin = #"""
        {"spokenText":"","intent":"action","payload":{"name":"draw_annotation","args":{"shapes":[{"kind":"rect","x":0,"y":0,"width":1,"height":1,"strokeWidth":0.1}]}}}
        """#
        let parseTooThin = PaceActionTagParser.parseActions(from: plannerResponseTooThin)
        guard case .drawAnnotation(let tooThinRequest) = parseTooThin.actions[0] else {
            Issue.record("Expected drawAnnotation")
            return
        }
        #expect(tooThinRequest.shapes[0].style.strokeWidth == 1.0)

        let plannerResponseTooThick = #"""
        {"spokenText":"","intent":"action","payload":{"name":"draw_annotation","args":{"shapes":[{"kind":"rect","x":0,"y":0,"width":1,"height":1,"strokeWidth":99}]}}}
        """#
        let parseTooThick = PaceActionTagParser.parseActions(from: plannerResponseTooThick)
        guard case .drawAnnotation(let tooThickRequest) = parseTooThick.actions[0] else {
            Issue.record("Expected drawAnnotation")
            return
        }
        #expect(tooThickRequest.shapes[0].style.strokeWidth == 12.0)
    }

    @Test func labelIsTrimmedAndCappedAtSixtyChars() async throws {
        let overlongLabel = String(repeating: "a", count: 200)
        let plannerResponse = #"""
        {"spokenText":"","intent":"action","payload":{"name":"draw_annotation","args":{"shapes":[{"kind":"rect","x":0,"y":0,"width":1,"height":1,"label":"   \#(overlongLabel)   "}]}}}
        """#
        let parseResult = PaceActionTagParser.parseActions(from: plannerResponse)
        guard case .drawAnnotation(let annotationRequest) = parseResult.actions[0] else {
            Issue.record("Expected drawAnnotation")
            return
        }
        let label = annotationRequest.shapes[0].style.label
        try #require(label != nil)
        #expect(label!.count == 60)
        #expect(!label!.hasPrefix(" "))
    }

    // MARK: - Failure / truncation paths

    @Test func emptyShapesArrayProducesNoAction() async throws {
        let plannerResponse = #"""
        {"spokenText":"","intent":"action","payload":{"name":"draw_annotation","args":{"shapes":[]}}}
        """#
        let parseResult = PaceActionTagParser.parseActions(from: plannerResponse)
        #expect(parseResult.actions.isEmpty)
    }

    @Test func polygonWithTwoVerticesIsRejected() async throws {
        let plannerResponse = #"""
        {"spokenText":"","intent":"action","payload":{"name":"draw_annotation","args":{"shapes":[{"kind":"polygon","points":[[0,0],[10,10]]}]}}}
        """#
        let parseResult = PaceActionTagParser.parseActions(from: plannerResponse)
        #expect(parseResult.actions.isEmpty)
    }

    @Test func excessShapesAreTruncatedAtCap() async throws {
        let manyShapes = (0..<50).map { _ in #"{"kind":"rect","x":0,"y":0,"width":1,"height":1}"# }.joined(separator: ",")
        let plannerResponse = #"""
        {"spokenText":"","intent":"action","payload":{"name":"draw_annotation","args":{"shapes":[\#(manyShapes)]}}}
        """#
        let parseResult = PaceActionTagParser.parseActions(from: plannerResponse)
        guard case .drawAnnotation(let annotationRequest) = parseResult.actions[0] else {
            Issue.record("Expected drawAnnotation")
            return
        }
        #expect(annotationRequest.shapes.count == PaceAnnotationRequest.maximumShapeCount)
    }

    // MARK: - clear_annotations

    @Test func clearAnnotationsParsesFromV10EnvelopeWithNoArgs() async throws {
        let plannerResponse = #"""
        {"spokenText":"clearing.","intent":"action","payload":{"name":"clear_annotations"}}
        """#
        let parseResult = PaceActionTagParser.parseActions(from: plannerResponse)
        try #require(parseResult.actions.count == 1)
        if case .clearAnnotations = parseResult.actions[0] {
            // expected
        } else {
            Issue.record("Expected clearAnnotations")
        }
    }

    @Test func clearAnnotationsParsesFromLegacyToolCallBlock() async throws {
        let plannerResponse = """
        sure.
        <tool_calls>
        [[{"tool":"clear_annotations"}]]
        </tool_calls>
        """
        let parseResult = PaceActionTagParser.parseActions(from: plannerResponse)
        try #require(parseResult.actions.count == 1)
        if case .clearAnnotations = parseResult.actions[0] {
            // expected
        } else {
            Issue.record("Expected clearAnnotations from <tool_calls>")
        }
    }

    // MARK: - Legacy <tool_calls> block path

    @Test func drawAnnotationParsesFromLegacyToolCallBlock() async throws {
        let plannerResponse = """
        watch this.
        <tool_calls>
        [[{"tool":"draw_annotation","shapes":[{"kind":"rect","x":1,"y":2,"width":3,"height":4}],"screen":2}]]
        </tool_calls>
        """
        let parseResult = PaceActionTagParser.parseActions(from: plannerResponse)
        try #require(parseResult.actions.count == 1)
        guard case .drawAnnotation(let annotationRequest) = parseResult.actions[0] else {
            Issue.record("Expected drawAnnotation from <tool_calls>")
            return
        }
        #expect(annotationRequest.screenNumber == 2)
        #expect(annotationRequest.shapes.count == 1)
    }
}
