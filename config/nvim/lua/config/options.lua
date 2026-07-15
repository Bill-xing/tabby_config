local opt = vim.opt

opt.conceallevel = 0
opt.fileencoding = "utf-8"
opt.fileencodings = { "ucs-bom", "utf-8", "gb18030", "gbk", "gb2312", "cp936", "big5", "latin1" }
opt.breakindent = true
opt.showbreak = "-> "
opt.spell = false
opt.formatoptions:append({ "m", "M" })
