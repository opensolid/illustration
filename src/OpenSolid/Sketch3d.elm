module OpenSolid.Sketch3d
    exposing
        ( Sketch3d
        , curve
        , group
        , indexedTriangles
        , mirrorAcross
        , placeIn
        , points
        , relativeTo
        , render
        , rotateAround
        , translateBy
        )

import Array.Hamt as Array
import Color exposing (Color)
import Html exposing (Html)
import Html.Attributes
import Math.Matrix4 exposing (Mat4)
import Math.Vector2 exposing (Vec2, vec2)
import Math.Vector3 exposing (Vec3, vec3)
import Math.Vector4 exposing (Vec4, vec4)
import OpenSolid.BoundingBox3d as BoundingBox3d
import OpenSolid.Frame3d as Frame3d
import OpenSolid.Geometry.Types exposing (..)
import OpenSolid.Point3d as Point3d
import OpenSolid.Sketch3d.EdgeSet as EdgeSet exposing (EdgeSet)
import OpenSolid.Triangle3d as Triangle3d
import OpenSolid.Vector3d as Vector3d
import OpenSolid.WebGL.Camera as Camera exposing (Camera)
import OpenSolid.WebGL.Frame3d as Frame3d
import OpenSolid.WebGL.Point3d as Point3d
import WebGL
import WebGL.Settings
import WebGL.Settings.DepthTest
import WebGL.Texture as Texture exposing (Texture)


type alias SurfaceVertex =
    { position : Point3d
    , edgeDistances : ( Float, Float, Float )
    }


type alias CachedSurfaceVertex =
    { position : Point3d
    , edgeDistances : Vec3
    , color : Vec3
    }


type alias SurfaceVertexAttributes =
    { position : Vec3
    , edgeDistances : Vec3
    , color : Vec3
    }


type alias Face =
    ( SurfaceVertex, SurfaceVertex, SurfaceVertex )


type alias CachedFace =
    ( CachedSurfaceVertex, CachedSurfaceVertex, CachedSurfaceVertex )


type alias FaceAttributes =
    ( SurfaceVertexAttributes, SurfaceVertexAttributes, SurfaceVertexAttributes )


type alias CachedCurveVertex =
    { position : Point3d
    , color : Vec4
    }


type alias CurveVertexAttributes =
    { position : Vec3
    , color : Vec4
    }


type alias Edge =
    ( Point3d, Point3d )


type alias CachedEdge =
    ( CachedCurveVertex, CachedCurveVertex )


type alias EdgeAttributes =
    ( CurveVertexAttributes, CurveVertexAttributes )


type alias CachedPoint =
    { position : Point3d
    , fill : Vec3
    , stroke : Vec3
    , radius : Float
    }


type alias PointAttributes =
    { position : Vec3
    , fill : Vec3
    , stroke : Vec3
    , radius : Float
    }


type Sketch3d
    = Surface
        { mesh : WebGL.Mesh SurfaceVertexAttributes
        , cachedFaces : List CachedFace
        , boundingBox : BoundingBox3d
        }
    | Curve
        { mesh : WebGL.Mesh CurveVertexAttributes
        , cachedEdges : List CachedEdge
        , boundingBox : BoundingBox3d
        }
    | Points
        { mesh : WebGL.Mesh PointAttributes
        , cachedPoints : List CachedPoint
        , boundingBox : BoundingBox3d
        }
    | Placed
        { placementFrame : Frame3d
        , isMirror : Bool
        , sketch : Sketch3d
        }
    | Group (List Sketch3d)
    | Empty


toVec3 : Color -> Vec3
toVec3 color_ =
    let
        { red, green, blue } =
            Color.toRgb color_
    in
    vec3
        (toFloat red / 255.0)
        (toFloat green / 255.0)
        (toFloat blue / 255.0)


toVec4 : Color -> Vec4
toVec4 color_ =
    let
        { red, green, blue, alpha } =
            Color.toRgb color_
    in
    vec4
        (toFloat red / 255.0)
        (toFloat green / 255.0)
        (toFloat blue / 255.0)
        alpha


toCachedSurfaceVertex : Vec3 -> SurfaceVertex -> CachedSurfaceVertex
toCachedSurfaceVertex color surfaceVertex =
    { position = surfaceVertex.position
    , edgeDistances = Math.Vector3.fromTuple surfaceVertex.edgeDistances
    , color = color
    }


toSurfaceVertexAttributes : CachedSurfaceVertex -> SurfaceVertexAttributes
toSurfaceVertexAttributes cachedSurfaceVertex =
    { position = Point3d.toVec3 cachedSurfaceVertex.position
    , edgeDistances = cachedSurfaceVertex.edgeDistances
    , color = cachedSurfaceVertex.color
    }


toCachedFace : Vec3 -> Face -> CachedFace
toCachedFace color ( firstSurfaceVertex, secondSurfaceVertex, thirdSurfaceVertex ) =
    ( toCachedSurfaceVertex color firstSurfaceVertex
    , toCachedSurfaceVertex color secondSurfaceVertex
    , toCachedSurfaceVertex color thirdSurfaceVertex
    )


toFaceAttributes : CachedFace -> FaceAttributes
toFaceAttributes ( cachedSurfaceVertex1, cachedSurfaceVertex2, cachedSurfaceVertex3 ) =
    ( toSurfaceVertexAttributes cachedSurfaceVertex1
    , toSurfaceVertexAttributes cachedSurfaceVertex2
    , toSurfaceVertexAttributes cachedSurfaceVertex3
    )


toCachedCurveVertex : Vec4 -> Point3d -> CachedCurveVertex
toCachedCurveVertex color position =
    { position = position
    , color = color
    }


toCurveVertexAttributes : CachedCurveVertex -> CurveVertexAttributes
toCurveVertexAttributes cachedCurveVertex =
    { position = Point3d.toVec3 cachedCurveVertex.position
    , color = cachedCurveVertex.color
    }


toCachedEdge : Vec4 -> Edge -> CachedEdge
toCachedEdge color ( startPosition, endPosition ) =
    ( toCachedCurveVertex color startPosition
    , toCachedCurveVertex color endPosition
    )


toEdgeAttributes : CachedEdge -> EdgeAttributes
toEdgeAttributes ( cachedStartVertex, cachedEndVertex ) =
    ( toCurveVertexAttributes cachedStartVertex
    , toCurveVertexAttributes cachedEndVertex
    )


toCachedPoint : Float -> Vec3 -> Vec3 -> Point3d -> CachedPoint
toCachedPoint radius fill stroke point =
    { position = point
    , fill = fill
    , stroke = stroke
    , radius = radius
    }


toPointAttributes : CachedPoint -> PointAttributes
toPointAttributes cachedPoint =
    { position = Point3d.toVec3 cachedPoint.position
    , fill = cachedPoint.fill
    , stroke = cachedPoint.stroke
    , radius = cachedPoint.radius
    }


faceBounds : Face -> BoundingBox3d
faceBounds ( firstVertex, secondVertex, thirdVertex ) =
    Triangle3d.boundingBox <|
        Triangle3d
            ( firstVertex.position
            , secondVertex.position
            , thirdVertex.position
            )


edgeBounds : Edge -> BoundingBox3d
edgeBounds ( startPosition, endPosition ) =
    Point3d.hull startPosition endPosition


inf : Float
inf =
    1.0 / 0.0


infs : ( Float, Float, Float )
infs =
    ( inf, inf, inf )


twiceArea p1 p2 p3 =
    Vector3d.length <|
        Vector3d.crossProduct
            (Point3d.vectorFrom p1 p2)
            (Point3d.vectorFrom p1 p3)


assembleFace : EdgeSet -> Int -> Int -> Int -> Point3d -> Point3d -> Point3d -> Face
assembleFace edgeSet i1 i2 i3 p1 p2 p3 =
    if EdgeSet.isEdgeVertex i1 edgeSet then
        if EdgeSet.isEdgeVertex i2 edgeSet then
            if EdgeSet.isEdgeVertex i3 edgeSet then
                -- All vertices are on edges
                if EdgeSet.isOpenEdge i1 i2 edgeSet then
                    if EdgeSet.isOpenEdge i1 i3 edgeSet then
                        if EdgeSet.isOpenEdge i2 i3 edgeSet then
                            -- e12, e13, e23
                            let
                                twoA =
                                    twiceArea p1 p2 p3

                                d1 =
                                    twoA / Point3d.distanceFrom p2 p3

                                d2 =
                                    twoA / Point3d.distanceFrom p1 p3

                                d3 =
                                    twoA / Point3d.distanceFrom p1 p2
                            in
                            ( { position = p1, edgeDistances = ( 0, 0, d1 ) }
                            , { position = p2, edgeDistances = ( 0, d2, 0 ) }
                            , { position = p3, edgeDistances = ( d3, 0, 0 ) }
                            )
                        else
                            -- e12, e13
                            let
                                twoA =
                                    twiceArea p1 p2 p3

                                d2 =
                                    twoA / Point3d.distanceFrom p1 p3

                                d3 =
                                    twoA / Point3d.distanceFrom p1 p2
                            in
                            ( { position = p1, edgeDistances = ( 0, 0, inf ) }
                            , { position = p2, edgeDistances = ( 0, d2, inf ) }
                            , { position = p3, edgeDistances = ( d3, 0, inf ) }
                            )
                    else if EdgeSet.isOpenEdge i2 i3 edgeSet then
                        -- e12, e23
                        let
                            twoA =
                                twiceArea p1 p2 p3

                            d1 =
                                twoA / Point3d.distanceFrom p2 p3

                            d3 =
                                twoA / Point3d.distanceFrom p1 p2
                        in
                        ( { position = p1, edgeDistances = ( 0, d1, inf ) }
                        , { position = p2, edgeDistances = ( 0, 0, inf ) }
                        , { position = p3, edgeDistances = ( d3, 0, inf ) }
                        )
                    else
                        -- e12, v3
                        let
                            d3 =
                                twiceArea p1 p2 p3 / Point3d.distanceFrom p1 p2

                            d13 =
                                Point3d.distanceFrom p1 p3

                            d23 =
                                Point3d.distanceFrom p2 p3
                        in
                        ( { position = p1, edgeDistances = ( 0, d13, inf ) }
                        , { position = p2, edgeDistances = ( 0, d23, inf ) }
                        , { position = p3, edgeDistances = ( d3, 0, inf ) }
                        )
                else if EdgeSet.isOpenEdge i1 i3 edgeSet then
                    if EdgeSet.isOpenEdge i2 i3 edgeSet then
                        -- e13, e23
                        let
                            twoA =
                                twiceArea p1 p2 p3

                            d1 =
                                twoA / Point3d.distanceFrom p2 p3

                            d2 =
                                twoA / Point3d.distanceFrom p1 p3
                        in
                        ( { position = p1, edgeDistances = ( 0, d1, inf ) }
                        , { position = p2, edgeDistances = ( d2, 0, inf ) }
                        , { position = p3, edgeDistances = ( 0, 0, inf ) }
                        )
                    else
                        -- e13, v2
                        let
                            d2 =
                                twiceArea p1 p2 p3 / Point3d.distanceFrom p1 p3

                            d12 =
                                Point3d.distanceFrom p1 p2

                            d23 =
                                Point3d.distanceFrom p2 p3
                        in
                        ( { position = p1, edgeDistances = ( 0, d12, inf ) }
                        , { position = p2, edgeDistances = ( d2, 0, inf ) }
                        , { position = p3, edgeDistances = ( 0, d23, inf ) }
                        )
                else if EdgeSet.isOpenEdge i2 i3 edgeSet then
                    -- e23, v1
                    let
                        d1 =
                            twiceArea p1 p2 p3 / Point3d.distanceFrom p2 p3

                        d12 =
                            Point3d.distanceFrom p1 p2

                        d13 =
                            Point3d.distanceFrom p1 p3
                    in
                    ( { position = p1, edgeDistances = ( d1, 0, inf ) }
                    , { position = p2, edgeDistances = ( 0, d12, inf ) }
                    , { position = p3, edgeDistances = ( 0, d13, inf ) }
                    )
                else
                    -- v1, v2, v3
                    let
                        d12 =
                            Point3d.distanceFrom p1 p2

                        d13 =
                            Point3d.distanceFrom p1 p3

                        d23 =
                            Point3d.distanceFrom p2 p3
                    in
                    ( { position = p1, edgeDistances = ( 0, d12, d13 ) }
                    , { position = p2, edgeDistances = ( d12, 0, d23 ) }
                    , { position = p3, edgeDistances = ( d13, d23, 0 ) }
                    )
            else if EdgeSet.isOpenEdge i1 i2 edgeSet then
                -- e12
                let
                    d3 =
                        twiceArea p1 p2 p3 / Point3d.distanceFrom p1 p2
                in
                ( { position = p1, edgeDistances = ( 0, inf, inf ) }
                , { position = p2, edgeDistances = ( 0, inf, inf ) }
                , { position = p3, edgeDistances = ( d3, inf, inf ) }
                )
            else
                -- v1, v2
                let
                    d12 =
                        Point3d.distanceFrom p1 p2

                    d13 =
                        Point3d.distanceFrom p1 p3

                    d23 =
                        Point3d.distanceFrom p2 p3
                in
                ( { position = p1, edgeDistances = ( 0, d12, inf ) }
                , { position = p2, edgeDistances = ( d12, 0, inf ) }
                , { position = p3, edgeDistances = ( d13, d23, inf ) }
                )
        else if EdgeSet.isEdgeVertex i3 edgeSet then
            if EdgeSet.isOpenEdge i1 i3 edgeSet then
                -- e13
                let
                    d2 =
                        twiceArea p1 p2 p3 / Point3d.distanceFrom p1 p3
                in
                ( { position = p1, edgeDistances = ( 0, inf, inf ) }
                , { position = p2, edgeDistances = ( d2, inf, inf ) }
                , { position = p3, edgeDistances = ( 0, inf, inf ) }
                )
            else
                -- v1, v3
                let
                    d12 =
                        Point3d.distanceFrom p1 p2

                    d13 =
                        Point3d.distanceFrom p1 p3

                    d23 =
                        Point3d.distanceFrom p2 p3
                in
                ( { position = p1, edgeDistances = ( 0, d13, inf ) }
                , { position = p2, edgeDistances = ( d12, d23, inf ) }
                , { position = p3, edgeDistances = ( d13, 0, inf ) }
                )
        else
            -- v1
            let
                d2 =
                    Point3d.distanceFrom p1 p2

                d3 =
                    Point3d.distanceFrom p1 p3
            in
            ( { position = p1, edgeDistances = ( 0, inf, inf ) }
            , { position = p2, edgeDistances = ( d2, inf, inf ) }
            , { position = p3, edgeDistances = ( d3, inf, inf ) }
            )
    else if EdgeSet.isEdgeVertex i2 edgeSet then
        if EdgeSet.isEdgeVertex i3 edgeSet then
            if EdgeSet.isOpenEdge i2 i3 edgeSet then
                -- e23
                let
                    d1 =
                        twiceArea p1 p2 p3 / Point3d.distanceFrom p2 p3
                in
                ( { position = p1, edgeDistances = ( d1, inf, inf ) }
                , { position = p2, edgeDistances = ( 0, inf, inf ) }
                , { position = p3, edgeDistances = ( 0, inf, inf ) }
                )
            else
                -- v2, v3
                let
                    d12 =
                        Point3d.distanceFrom p1 p2

                    d13 =
                        Point3d.distanceFrom p1 p3

                    d23 =
                        Point3d.distanceFrom p2 p3
                in
                ( { position = p1, edgeDistances = ( d12, d13, inf ) }
                , { position = p2, edgeDistances = ( 0, d23, inf ) }
                , { position = p3, edgeDistances = ( d23, 0, inf ) }
                )
        else
            -- v2
            let
                d1 =
                    Point3d.distanceFrom p2 p1

                d3 =
                    Point3d.distanceFrom p2 p3
            in
            ( { position = p1, edgeDistances = ( d1, inf, inf ) }
            , { position = p2, edgeDistances = ( 0, inf, inf ) }
            , { position = p3, edgeDistances = ( d3, inf, inf ) }
            )
    else if EdgeSet.isEdgeVertex i3 edgeSet then
        -- v3
        let
            d1 =
                Point3d.distanceFrom p3 p1

            d2 =
                Point3d.distanceFrom p3 p2
        in
        ( { position = p1, edgeDistances = ( d1, inf, inf ) }
        , { position = p2, edgeDistances = ( d2, inf, inf ) }
        , { position = p3, edgeDistances = ( 0, inf, inf ) }
        )
    else
        ( { position = p1, edgeDistances = infs }
        , { position = p2, edgeDistances = infs }
        , { position = p3, edgeDistances = infs }
        )


indexedTriangles : Color -> List Point3d -> List ( Int, Int, Int ) -> Sketch3d
indexedTriangles color points faceIndices =
    let
        pointArray =
            Array.fromList points

        edgeSet =
            EdgeSet.build faceIndices

        toFace ( i1, i2, i3 ) =
            Maybe.map3
                (assembleFace edgeSet i1 i2 i3)
                (Array.get i1 pointArray)
                (Array.get i2 pointArray)
                (Array.get i3 pointArray)

        faces =
            List.filterMap toFace faceIndices

        toEdge ( i, j ) =
            Maybe.map2 (,) (Array.get i pointArray) (Array.get j pointArray)

        edges =
            List.filterMap toEdge (EdgeSet.openEdges edgeSet)
    in
    group [ surface color faces, curve (Color.rgba 0 0 0 0.5) edges ]


surface : Color -> List Face -> Sketch3d
surface color faces =
    case BoundingBox3d.hullOf (List.map faceBounds faces) of
        Just boundingBox ->
            let
                cachedFaces =
                    List.map (toCachedFace (toVec3 color)) faces

                faceAttributes =
                    List.map toFaceAttributes cachedFaces

                mesh =
                    WebGL.triangles faceAttributes
            in
            Surface
                { mesh = mesh
                , cachedFaces = cachedFaces
                , boundingBox = boundingBox
                }

        Nothing ->
            Empty


curve : Color -> List Edge -> Sketch3d
curve color edges =
    case BoundingBox3d.hullOf (List.map edgeBounds edges) of
        Just boundingBox ->
            let
                cachedEdges =
                    List.map (toCachedEdge (toVec4 color)) edges

                edgeAttributes =
                    List.map toEdgeAttributes cachedEdges

                mesh =
                    WebGL.lines edgeAttributes
            in
            Curve
                { mesh = mesh
                , cachedEdges = cachedEdges
                , boundingBox = boundingBox
                }

        Nothing ->
            Empty


points : Float -> { fill : Color, stroke : Color } -> List Point3d -> Sketch3d
points radius colors points_ =
    case BoundingBox3d.containing points_ of
        Just boundingBox ->
            let
                fill =
                    toVec3 colors.fill

                stroke =
                    toVec3 colors.stroke

                cachedPoints =
                    List.map (toCachedPoint radius fill stroke) points_

                pointAttributes =
                    List.map toPointAttributes cachedPoints

                mesh =
                    WebGL.points pointAttributes
            in
            Points
                { mesh = mesh
                , cachedPoints = cachedPoints
                , boundingBox = boundingBox
                }

        Nothing ->
            Empty


group : List Sketch3d -> Sketch3d
group =
    Group


transformBy : (Frame3d -> Frame3d) -> Bool -> Sketch3d -> Sketch3d
transformBy frameTransformation isMirror sketch =
    case sketch of
        Surface _ ->
            Placed
                { placementFrame = frameTransformation Frame3d.xyz
                , isMirror = isMirror
                , sketch = sketch
                }

        Curve _ ->
            Placed
                { placementFrame = frameTransformation Frame3d.xyz
                , isMirror = isMirror
                , sketch = sketch
                }

        Points _ ->
            Placed
                { placementFrame = frameTransformation Frame3d.xyz
                , isMirror = isMirror
                , sketch = sketch
                }

        Group _ ->
            Placed
                { placementFrame = frameTransformation Frame3d.xyz
                , isMirror = isMirror
                , sketch = sketch
                }

        Placed properties ->
            let
                updatedFrame =
                    frameTransformation properties.placementFrame

                updatedIsMirror =
                    isMirror /= properties.isMirror
            in
            Placed
                { placementFrame = updatedFrame
                , isMirror = updatedIsMirror
                , sketch = properties.sketch
                }

        Empty ->
            Empty


translateBy : Vector3d -> Sketch3d -> Sketch3d
translateBy displacement sketch =
    transformBy (Frame3d.translateBy displacement) False sketch


rotateAround : Axis3d -> Float -> Sketch3d -> Sketch3d
rotateAround axis angle sketch =
    transformBy (Frame3d.rotateAround axis angle) False sketch


mirrorAcross : Plane3d -> Sketch3d -> Sketch3d
mirrorAcross plane sketch =
    transformBy (Frame3d.mirrorAcross plane) True sketch


placeIn : Frame3d -> Sketch3d -> Sketch3d
placeIn frame sketch =
    let
        isMirror =
            Frame3d.isRightHanded frame
    in
    transformBy (Frame3d.placeIn frame) isMirror sketch


relativeTo : Frame3d -> Sketch3d -> Sketch3d
relativeTo frame sketch =
    let
        isMirror =
            Frame3d.isRightHanded frame
    in
    transformBy (Frame3d.relativeTo frame) isMirror sketch


type alias SurfaceUniforms =
    { pixelScale : Float
    , modelViewProjectionMatrix : Mat4
    }


type alias SurfaceVaryings =
    { interpolatedColor : Vec3
    , interpolatedEdgeDistances : Vec3
    , interpolatedPixelsPerUnit : Float
    }


surfaceVertexShader : WebGL.Shader SurfaceVertexAttributes SurfaceUniforms SurfaceVaryings
surfaceVertexShader =
    [glsl|
        attribute vec3 position;
        attribute vec3 color;
        attribute vec3 edgeDistances;

        uniform float pixelScale;
        uniform mat4 modelViewProjectionMatrix;

        varying vec3 interpolatedColor;
        varying vec3 interpolatedEdgeDistances;
        varying float interpolatedPixelsPerUnit;

        void main () {
            gl_Position = modelViewProjectionMatrix * vec4(position, 1.0);
            interpolatedColor = color;
            interpolatedEdgeDistances = edgeDistances;
            interpolatedPixelsPerUnit = pixelScale / gl_Position.w;
        }
    |]


surfaceFragmentShader : WebGL.Shader {} SurfaceUniforms SurfaceVaryings
surfaceFragmentShader =
    WebGL.unsafeShader
        """#extension GL_OES_standard_derivatives : enable

        precision mediump float;

        varying vec3 interpolatedColor;
        varying vec3 interpolatedEdgeDistances;
        varying float interpolatedPixelsPerUnit;

        void main() {
            float distance1 = interpolatedEdgeDistances.x;
            float distance2 = interpolatedEdgeDistances.y;
            float distance3 = interpolatedEdgeDistances.z;

            float gradientSlope1 = length(vec2(dFdx(distance1), dFdy(distance1)));
            float gradientSlope2 = length(vec2(dFdx(distance2), dFdy(distance2)));
            float gradientSlope3 = length(vec2(dFdx(distance3), dFdy(distance3)));

            float pixelDistance1 = distance1 / gradientSlope1;
            float pixelDistance2 = distance2 / gradientSlope2;
            float pixelDistance3 = distance3 / gradientSlope3;

            float pixelDistance = min(pixelDistance1, min(pixelDistance2, pixelDistance3));
            float colorScale = clamp(pixelDistance, 0.0, 1.0);
            gl_FragColor = vec4(interpolatedColor * colorScale, 1.0);
        }"""


surfaceToEntity : Camera -> Float -> Frame3d -> Bool -> WebGL.Mesh SurfaceVertexAttributes -> WebGL.Entity
surfaceToEntity camera pixelScale placementFrame isMirror mesh =
    let
        modelViewMatrix =
            Frame3d.modelViewMatrix (Camera.frame camera) placementFrame

        projectionMatrix =
            Camera.projectionMatrix camera

        modelViewProjectionMatrix =
            Math.Matrix4.mul projectionMatrix modelViewMatrix

        cullSetting =
            if isMirror then
                WebGL.Settings.front
            else
                WebGL.Settings.back

        settings =
            [ WebGL.Settings.DepthTest.default
            , WebGL.Settings.cullFace cullSetting
            ]

        uniforms =
            { pixelScale = pixelScale
            , modelViewProjectionMatrix = modelViewProjectionMatrix
            }
    in
    WebGL.entityWith settings
        surfaceVertexShader
        surfaceFragmentShader
        mesh
        uniforms


type alias CurveUniforms =
    { modelViewProjectionMatrix : Mat4
    }


type alias CurveVaryings =
    { interpolatedColor : Vec4
    }


curveVertexShader : WebGL.Shader CurveVertexAttributes CurveUniforms CurveVaryings
curveVertexShader =
    [glsl|
        attribute vec3 position;
        attribute vec4 color;

        uniform mat4 modelViewProjectionMatrix;

        varying vec4 interpolatedColor;

        void main () {
            gl_Position = modelViewProjectionMatrix * vec4(position, 1.0);
            interpolatedColor = color;
        }
    |]


curveFragmentShader : WebGL.Shader {} CurveUniforms CurveVaryings
curveFragmentShader =
    [glsl|
        precision mediump float;

        varying vec4 interpolatedColor;

        void main() {
            gl_FragColor = interpolatedColor;
        }
    |]


curveToEntity : Camera -> Frame3d -> WebGL.Mesh CurveVertexAttributes -> WebGL.Entity
curveToEntity camera placementFrame mesh =
    let
        modelViewMatrix =
            Frame3d.modelViewMatrix (Camera.frame camera) placementFrame

        projectionMatrix =
            Camera.projectionMatrix camera

        modelViewProjectionMatrix =
            Math.Matrix4.mul projectionMatrix modelViewMatrix

        uniforms =
            { modelViewProjectionMatrix = modelViewProjectionMatrix
            }
    in
    WebGL.entity curveVertexShader curveFragmentShader mesh uniforms


type alias PointUniforms =
    { modelViewProjectionMatrix : Mat4
    }


type alias PointVaryings =
    { interpolatedFill : Vec3
    , interpolatedStroke : Vec3
    , interpolatedRadius : Float
    }


pointVertexShader : WebGL.Shader PointAttributes PointUniforms PointVaryings
pointVertexShader =
    [glsl|
        attribute vec3 position;
        attribute vec3 fill;
        attribute vec3 stroke;
        attribute float radius;

        uniform mat4 modelViewProjectionMatrix;

        varying vec3 interpolatedFill;
        varying vec3 interpolatedStroke;
        varying float interpolatedRadius;

        void main() {
            gl_Position = modelViewProjectionMatrix * vec4(position, 1.0);
            gl_PointSize = 2.0 * radius;
        }
    |]


pointFragmentShader : WebGL.Shader {} PointUniforms PointVaryings
pointFragmentShader =
    [glsl|
        precision mediump float;

        varying vec3 interpolatedFill;
        varying vec3 interpolatedStroke;
        varying float interpolatedRadius;

        void main() {
            float radius = interpolatedRadius;
            vec3 fill = interpolatedFill;
            vec3 stroke = interpolatedStroke;
            float x = (2.0 * gl_PointCoord.x - 1.0);
            float y = (1.0 - 2.0 * gl_PointCoord.y);
            float r2 = x * x + y * y;
            float r = sqrt(r2);
            float t = clamp(0.5 * (r - radius), 0.0, 1.0);
            if (r > 1.0) {
                discard;
            }
            gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
            //gl_FragColor = vec4(mix(fill, stroke, t), 1.0);
        }
    |]


pointsToEntity : Camera -> Frame3d -> WebGL.Mesh PointAttributes -> WebGL.Entity
pointsToEntity camera placementFrame mesh =
    let
        modelViewMatrix =
            Frame3d.modelViewMatrix (Camera.frame camera) placementFrame

        projectionMatrix =
            Camera.projectionMatrix camera

        modelViewProjectionMatrix =
            Math.Matrix4.mul projectionMatrix modelViewMatrix

        uniforms =
            { modelViewProjectionMatrix = modelViewProjectionMatrix
            }
    in
    WebGL.entity pointVertexShader pointFragmentShader mesh uniforms


collectEntities : Camera -> Float -> Frame3d -> Bool -> Sketch3d -> List WebGL.Entity -> List WebGL.Entity
collectEntities camera pixelScale currentFrame currentMirror sketch accumulated =
    case sketch of
        Surface { mesh } ->
            surfaceToEntity camera pixelScale currentFrame currentMirror mesh :: accumulated

        Curve { mesh } ->
            curveToEntity camera currentFrame mesh :: accumulated

        Points { mesh } ->
            pointsToEntity camera currentFrame mesh :: accumulated

        Placed properties ->
            collectEntities
                camera
                pixelScale
                (Frame3d.placeIn currentFrame properties.placementFrame)
                (currentMirror /= properties.isMirror)
                properties.sketch
                accumulated

        Group sketches ->
            List.foldl
                (collectEntities camera pixelScale currentFrame currentMirror)
                accumulated
                sketches

        Empty ->
            accumulated


render : Camera -> Sketch3d -> Html msg
render camera sketch =
    let
        width =
            Camera.screenWidth camera

        height =
            Camera.screenHeight camera

        projectionMatrix =
            Camera.projectionMatrix camera

        pixelScale =
            (Math.Matrix4.toRecord projectionMatrix).m11 * width / 2

        entities =
            collectEntities camera pixelScale Frame3d.xyz False sketch []
    in
    WebGL.toHtml
        [ Html.Attributes.width (2 * round width)
        , Html.Attributes.height (2 * round height)
        , Html.Attributes.style
            [ ( "width", toString width ++ "px" )
            , ( "height", toString height ++ "px" )
            ]
        ]
        entities
