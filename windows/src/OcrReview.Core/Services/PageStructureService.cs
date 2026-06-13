using OcrReview.Core.Models;

namespace OcrReview.Core.Services;

public static class PageStructureService
{
    public static List<OcrPage> RemapAfterDelete(List<OcrPage> pages, int deletedPageNumber)
    {
        var result = new List<OcrPage>();
        foreach (var page in pages)
        {
            if (page.PageNumber == deletedPageNumber) continue;
            if (page.PageNumber > deletedPageNumber) page.PageNumber -= 1;
            result.Add(page);
        }
        return result.OrderBy(p => p.PageNumber).ToList();
    }

    public static List<OcrPage> RemapAfterMove(List<OcrPage> pages, int fromIndex, int toIndex, int pageCount)
    {
        if (fromIndex < 0 || fromIndex >= pageCount || toIndex < 0 || toIndex >= pageCount)
            return pages;

        var slots = new List<OcrPage?>(pageCount);
        for (int i = 0; i < pageCount; i++)
            slots.Add(pages.FirstOrDefault(p => p.PageNumber == i + 1));

        var item = slots[fromIndex];
        slots.RemoveAt(fromIndex);
        slots.Insert(toIndex, item);

        var result = new List<OcrPage>();
        for (int i = 0; i < slots.Count; i++)
        {
            var page = slots[i];
            if (page == null) continue;
            page.PageNumber = i + 1;
            result.Add(page);
        }
        return result;
    }
}
