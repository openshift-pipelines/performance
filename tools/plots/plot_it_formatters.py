import matplotlib.ticker as tkr
import matplotlib.dates as md

# Formatter Methods
class Formatter:
    def __init__(self):
        self.formatter = {
            None: tkr.FuncFormatter(lambda x, pos: x),
            
            "compute_bytes": self.compute_bytes(),

            "time_hour": self.time_hour(),
        }

    def __call__(self, type:str):
        if type in self.formatter:
            return self.formatter[type]
        raise Exception("Invalid Formatter type defined!")

    def time_hour(self):
        return md.DateFormatter('%H:%M')

    def compute_bytes(self):
        def sizeof_fmt(x, pos):
            if x<0:
                return ""
            for x_unit in ['bytes', 'kB', 'MB', 'GB', 'TB']:
                if x < 1024.0:
                    return "%3.1f %s" % (x, x_unit)
                x /= 1024.0
        return tkr.FuncFormatter(sizeof_fmt)
