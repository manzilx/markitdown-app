namespace OcrReview.Core.Services;

/// <summary>
/// Sorts OCR line boxes into natural reading order. OCR engines return same-visual-row
/// fragments (table label vs value, multi-column content) out of order, and baseline
/// jitter makes a plain Y sort swap cells. Lines whose vertical extents overlap by
/// ≥50% of the smaller height form one visual row (read left→right); rows read
/// top→bottom.
/// </summary>
public static class ReadingOrderService
{
    /// <summary>Returns indexes into <paramref name="boxes"/> in reading order.
    /// Coordinates are top-left origin, any consistent units.</summary>
    public static List<int> Order(IReadOnlyList<(double X, double Y, double W, double H)> boxes)
    {
        var byTop = Enumerable.Range(0, boxes.Count).OrderBy(i => boxes[i].Y).ToList();
        var rows = new List<List<int>>();
        var rowTop = new List<double>();
        var rowBottom = new List<double>();

        foreach (var i in byTop)
        {
            var (_, y, _, h) = boxes[i];
            var bottom = y + h;
            var placed = false;
            for (var r = rows.Count - 1; r >= 0; r--)
            {
                var overlap = Math.Min(bottom, rowBottom[r]) - Math.Max(y, rowTop[r]);
                var minHeight = Math.Min(h, rowBottom[r] - rowTop[r]);
                if (overlap >= 0.5 * Math.Max(minHeight, 1e-9))
                {
                    rows[r].Add(i);
                    rowTop[r] = Math.Min(rowTop[r], y);
                    rowBottom[r] = Math.Max(rowBottom[r], bottom);
                    placed = true;
                    break;
                }
            }
            if (!placed)
            {
                rows.Add(new List<int> { i });
                rowTop.Add(y);
                rowBottom.Add(bottom);
            }
        }

        return rows
            .Select((row, r) => (Row: row, Top: rowTop[r]))
            .OrderBy(t => t.Top)
            .SelectMany(t => t.Row.OrderBy(i => boxes[i].X))
            .ToList();
    }
}
