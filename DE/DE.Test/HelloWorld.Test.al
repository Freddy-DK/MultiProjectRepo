codeunit 90031 "HelloWorld Test DE"
{
    Subtype = Test;

    [Test]
    procedure TestHelloWorldMessage()
    var
        CustList: TestPage "Customer List";
    begin
        CustList.OpenView();
        CustList.Close();
    end;
}

