import CoreGraphics

public enum MacDisplayCoordinateMapper {
  public static func absolutePoint(
    xPercent: Double,
    yPercent: Double,
    bounds: CGRect
  ) -> CGPoint? {
    guard xPercent.isFinite,
          yPercent.isFinite,
          !bounds.isNull,
          !bounds.isEmpty else {
      return nil
    }
    let x = CGFloat(min(max(xPercent, 0.0), 1.0))
    let y = CGFloat(min(max(yPercent, 0.0), 1.0))
    return CGPoint(
      x: bounds.minX + x * max(0.0, bounds.width - 1.0),
      y: bounds.minY + y * max(0.0, bounds.height - 1.0)
    )
  }

  public static func clamp(_ location: CGPoint, to bounds: CGRect) -> CGPoint? {
    guard location.x.isFinite,
          location.y.isFinite,
          !bounds.isNull,
          !bounds.isEmpty else {
      return nil
    }
    return CGPoint(
      x: min(max(location.x, bounds.minX), bounds.maxX - 1.0),
      y: min(max(location.y, bounds.minY), bounds.maxY - 1.0)
    )
  }

  public static func normalizedPoint(
    _ location: CGPoint,
    in bounds: CGRect
  ) -> (x: Double, y: Double)? {
    guard location.x.isFinite,
          location.y.isFinite,
          !bounds.isNull,
          !bounds.isEmpty else {
      return nil
    }
    return (
      x: min(max(Double((location.x - bounds.minX) / bounds.width), 0.0), 1.0),
      y: min(max(Double((location.y - bounds.minY) / bounds.height), 0.0), 1.0)
    )
  }
}
